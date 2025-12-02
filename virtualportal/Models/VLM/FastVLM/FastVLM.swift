//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2025 Apple Inc. All Rights Reserved.
//

@preconcurrency import CoreImage
@preconcurrency import CoreML
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXFast
@preconcurrency import MLXLMCommon
@preconcurrency import MLXNN
@preconcurrency import MLXVLM
@preconcurrency import Tokenizers

// FastVLM is Qwen2VL with a custom vision tower.

// MARK: - Common

/// Rotates half the hidden dims of the input
private func rotateHalf(_ x: MLXArray) -> MLXArray {
    let index = x.dim(-1) / 2
    let x1 = x[.ellipsis, 0 ..< index]
    let x2 = x[.ellipsis, index...]
    return concatenated([-x2, x1], axis: -1)
}

// MARK: - Language

private enum Language {

    /// Applies Rotary Position Embedding with Multimodal Sections to the query and key tensors
    static private func applyMultimodalRotaryPositionEmbedding(
        q: MLXArray, k: MLXArray, cos: MLXArray, sin: MLXArray,
        positionIds: MLXArray, mropeSection: [Int]
    ) -> (MLXArray, MLXArray) {
        var cos = cos[positionIds]
        var sin = sin[positionIds]

        cos =
            concatenated(
                // [m[i % 3] for i, m in enumerate(mx.split(cos, mrope_section, axis=-1))]
                split(cos, indices: mropeSection, axis: -1).enumerated().map { i, m in m[i % 3] },
                axis: -1
            )[0..., .newAxis, 0..., 0...]

        sin =
            concatenated(
                split(sin, indices: mropeSection, axis: -1).enumerated().map { i, m in m[i % 3] },
                axis: -1
            )[0..., .newAxis, 0..., 0...]

        // Apply rotary embedding
        let qEmbed = (q * cos) + (rotateHalf(q) * sin)
        let kEmbed = (k * cos) + (rotateHalf(k) * sin)
        return (qEmbed, kEmbed)
    }

    fileprivate class Attention: Module {

        let heads: Int
        let kvHeads: Int
        let headDim: Int
        let scale: Float
        var mropeSection: [Int]

        @ModuleInfo(key: "q_proj") var wq: Linear
        @ModuleInfo(key: "k_proj") var wk: Linear
        @ModuleInfo(key: "v_proj") var wv: Linear
        @ModuleInfo(key: "o_proj") var wo: Linear

        @ModuleInfo(key: "rotary_emb") var rotaryEmbedding: RoPE


        public init(_ args: FastVLMConfiguration.TextConfiguration) {
            let dim = args.hiddenSize
            self.heads = args.attentionHeads
            self.kvHeads = args.kvHeads
            self.headDim = dim / heads
            self.scale = pow(Float(headDim), -0.5)

            self._wq.wrappedValue = Linear(dim, heads * headDim, bias: true)
            self._wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: true)
            self._wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: true)
            self._wo.wrappedValue = Linear(heads * headDim, dim, bias: false)

            if let v = args.ropeScaling?["mrope_section"], let array = v.asInts() {
                // mrope_section = np.cumsum(mrope_section * 2)[:-1].tolist()
                self.mropeSection = sequence(state: (0, array.makeIterator())) { state in
                    if let v = state.1.next() {
                        // note the *2
                        state.0 += v * 2
                        return state.0
                    } else {
                        return nil
                    }
                }.dropLast()
            } else {
                fatalError("rope_scaling['mrope_section'] must be an array of integers")
            }

            self._rotaryEmbedding.wrappedValue = RoPE(
                dimensions: headDim, traditional: args.ropeTraditional, base: args.ropeTheta)
        }

        public func callAsFunction(
            _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil, cache: KVCache?
        ) -> MLXArray {
            let (B, L) = (x.dim(0), x.dim(1))

            var queries = wq(x)
            var keys = wk(x)
            var values = wv(x)

            // prepare the queries, keys and values for the attention computation
            queries = queries.reshaped(B, L, heads, headDim).transposed(0, 2, 1, 3)
            keys = keys.reshaped(B, L, kvHeads, headDim).transposed(0, 2, 1, 3)
            values = values.reshaped(B, L, kvHeads, headDim).transposed(0, 2, 1, 3)

            let offset = cache?.offset ?? 0
            // In newer API, mask is a ScaledDotProductAttentionMaskMode and passed through
            // directly to scaledDotProductAttention.
                // Optional mask provided by caller

            queries = rotaryEmbedding(queries, offset: offset)
            keys = rotaryEmbedding(keys, offset: offset)

            if let cache {
                (keys, values) = cache.update(keys: keys, values: values)
            }

                let sdpaMask = mask ?? .none
                let output = MLXFast.scaledDotProductAttention(
                    queries: queries, keys: keys, values: values, scale: scale, mask: sdpaMask
                )
                    .transposed(0, 2, 1, 3)
                    .reshaped(B, L, -1)
                return wo(output)
        }
    }

    fileprivate class MLP: Module, UnaryLayer {

        @ModuleInfo(key: "gate_proj") var gate: Linear
        @ModuleInfo(key: "down_proj") var down: Linear
        @ModuleInfo(key: "up_proj") var up: Linear


        public init(dimensions: Int, hiddenDimensions: Int) {
            self._gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
            self._down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
            self._up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        }

        public func callAsFunction(_ x: MLXArray) -> MLXArray {
            down(silu(gate(x)) * up(x))
        }
    }

    fileprivate class FastVLMDecoderLayer: Module {

        @ModuleInfo(key: "self_attn") var attention: Attention
        let mlp: MLP

        @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
        @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm


        public init(_ args: FastVLMConfiguration.TextConfiguration) {
            self._attention.wrappedValue = Attention(args)
            self.mlp = MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
            self._inputLayerNorm.wrappedValue = RMSNorm(
                dimensions: args.hiddenSize, eps: args.rmsNormEps)
            self._postAttentionLayerNorm.wrappedValue = RMSNorm(
                dimensions: args.hiddenSize, eps: args.rmsNormEps)
        }

        public func callAsFunction(
            _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil, cache: KVCache?
        ) -> MLXArray {
            var r = attention(inputLayerNorm(x), mask: mask, cache: cache)
            let h = x + r
            r = mlp(postAttentionLayerNorm(h))
            let out = h + r
            return out
        }
    }

    fileprivate class Qwen2Model: Module {

        @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

        fileprivate let layers: [FastVLMDecoderLayer]
        fileprivate let norm: RMSNorm


        public init(_ args: FastVLMConfiguration.TextConfiguration) {
            precondition(args.vocabularySize > 0)

            self._embedTokens.wrappedValue = Embedding(
                embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)

            self.layers = (0 ..< args.hiddenLayers)
                .map { _ in
                    FastVLMDecoderLayer(args)
                }
            self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        }

        public func callAsFunction(
            _ inputs: MLXArray?, cache: [KVCache]? = nil, inputEmbedding: MLXArray? = nil
        ) -> MLXArray {
            var h: MLXArray
            if let inputEmbedding {
                h = inputEmbedding
            } else if let inputs {
                h = embedTokens(inputs)
            } else {
                fatalError("one of inputs or inputEmbedding must be non-nil")
            }

            // createAttentionMask now returns a ScaledDotProductAttentionMaskMode
            let mask = createAttentionMask(h: h, cache: cache)

            for (i, layer) in layers.enumerated() {
                h = layer(h, mask: mask, cache: cache?[i])
            }

            return norm(h)
        }
    }

    fileprivate class LanguageModel: Module, KVCacheDimensionProvider {
        @ModuleInfo var model: Qwen2Model
        @ModuleInfo(key: "lm_head") var lmHead: Linear?

        let kvHeads: [Int]


        public init(_ args: FastVLMConfiguration.TextConfiguration) {
            self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
            self._model.wrappedValue = Qwen2Model(args)
            if !args.tieWordEmbeddings {
                _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
            }
        }

        public func callAsFunction(
            _ inputs: MLXArray?, cache: [KVCache]? = nil, inputEmbedding: MLXArray? = nil
        ) -> LMOutput {
            var out = model(inputs, cache: cache, inputEmbedding: inputEmbedding)
            if let lmHead {
                out = lmHead(out)
            } else {
                out = model.embedTokens.asLinear(out)
            }
            return LMOutput(logits: out)
        }
    }
}

// MARK: - Vision

private enum Vision {

    fileprivate class VisionModelCoreML {

        let lock = NSLock()
        var _model: fastvithd?
        nonisolated(unsafe) static var didLogInitSuccess = false
        nonisolated(unsafe) static var lastLockLog: Date? = nil

        nonisolated init() {
        }

        func load() throws -> fastvithd {
            // Throttle noisy lock logs using a static timestamp
            #if DEBUG
            let now = Date()
            if Self.lastLockLog == nil || now.timeIntervalSince(Self.lastLockLog!) > 5 {
                print("[VisionModelCoreML] attempting to acquire lock for model init at \(now)")
                Self.lastLockLog = now
            }
            #endif
            let deadline = Date().addingTimeInterval(10)
            guard lock.lock(before: deadline) else {
            throw NSError(domain: "VisionModelCoreML", code: 12,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for VisionModelCoreML lock to initialize model"])            
            }
            #if DEBUG
            let acquired = Date()
            if Self.lastLockLog == nil || acquired.timeIntervalSince(Self.lastLockLog!) > 5 {
                print("[VisionModelCoreML] acquired lock at \(acquired)")
                Self.lastLockLog = acquired
            }
            #endif
            defer {
            lock.unlock()
            }
                if let model = _model { return model }

                #if DEBUG
                let checkTime = Date()
                if Self.lastLockLog == nil || checkTime.timeIntervalSince(Self.lastLockLog!) > 5 {
                    print("[VisionModelCoreML] About to check resource presence and initialize model at \(checkTime)")
                    Self.lastLockLog = checkTime
                }
                #endif

                // Check typical bundles for compiled model resources; use search for
                // mlpackage or mlmodelc artifacts matching 'fastvithd' to reduce false-negatives.
                #if DEBUG
                let bundlesToCheck: [Bundle] = [Bundle(for: VisionModelCoreML.self), Bundle.main]
                var hasModelPackage = false
                var hasModelCompiled = false
                var printedNames = Set<String>()
                for bundle in bundlesToCheck {
                    if let urls = bundle.urls(forResourcesWithExtension: "mlpackage", subdirectory: nil) {
                        for url in urls {
                            let component = url.lastPathComponent.lowercased()
                            if component.contains("fastvithd") {
                                hasModelPackage = true
                                let name = url.lastPathComponent
                                if !printedNames.contains(name) {
                                    print("[VisionModelCoreML] Found mlpackage: \(name)")
                                    printedNames.insert(name)
                                }
                                break
                            }
                        }
                    }
                    if let urls = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) {
                        for url in urls {
                            let component = url.lastPathComponent.lowercased()
                            if component.contains("fastvithd") {
                                hasModelCompiled = true
                                let name = url.lastPathComponent
                                if !printedNames.contains(name) {
                                    print("[VisionModelCoreML] Found mlmodelc: \(name)")
                                    printedNames.insert(name)
                                }
                                break
                            }
                        }
                    }
                }
                if !hasModelPackage && !hasModelCompiled {
                    print("[VisionModelCoreML] Warning: fastvithd CoreML package not found in bundle during resource check")
                }
                #endif

                do {
#if DEBUG
                    print("[VisionModelCoreML] inside lock -- about to instantiate fastvithd()")
#endif
                    #if DEBUG
                    print("[VisionModelCoreML] Initializing CoreML model via fastvithd()...")
                    #endif
                    let model = try fastvithd()
                    _model = model
                    #if DEBUG
                    if !Self.didLogInitSuccess {
                        Self.didLogInitSuccess = true
                        print("[VisionModelCoreML] fastvithd() initialized successfully")
                    }
                    #endif
                    return model
                } catch {
                    #if DEBUG
                    print("[VisionModelCoreML] fastvithd() init failed: \(error)")
                    #endif
                    throw NSError(domain: "VisionModelCoreML", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "fastvithd initialization error: \(error)"])
                }
            }

        public func model() -> fastvithd? {
            do {
                return try self.load()
            } catch {
#if DEBUG
                print("[VisionModelCoreML] model load failed: \(error)")
#endif
                return nil
            }
        }

        public func encode(_ image: MLXArray) -> MLXArray {
            // MLMultiArray requires mutable input data
            var (data, strides) = {
                let arrayData = image.asType(.float32).asData(access: .noCopyIfContiguous)
                return (arrayData.data, arrayData.strides)
            }()

            guard image.ndim == 4, image.dim(0) == 1, image.dim(1) == 3 else {
#if DEBUG
                print("[VisionModelCoreML] unexpected image dims: ndim=\(image.ndim), dim0=\(image.dim(0)), dim1=\(image.dim(1))")
#endif
                let zeros = [Float32](repeating: 0.0, count: 1 * 256 * 3072)
                return zeros.withUnsafeBytes { ptr in
                    MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                }
            }

            let h = NSNumber(value: image.dim(2))
            let w = NSNumber(value: image.dim(3))

                return data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                // wrap the backing of the MLXArray
                let array: MLMultiArray
                do {
                    guard let basePtr = ptr.baseAddress else {
                        #if DEBUG
                        print("[VisionModelCoreML] MLMultiArray data pointer is nil; returning zeros")
                        #endif
                        let zeros = [Float32](repeating: 0.0, count: 1 * 256 * 3072)
                        return zeros.withUnsafeBytes { ptr in
                            MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                        }
                    }
                    array = try MLMultiArray(
                        dataPointer: basePtr, shape: [1, 3, h, w], dataType: .float32,
                        strides: strides.map { .init(value: $0) })
                } catch {
                    #if DEBUG
                    print("[VisionModelCoreML] MLMultiArray initialization failed: \(error)")
                    #endif
                    // Return zero features on failure describing an empty feature map
                    let zeros = [Float32](repeating: 0.0, count: 1 * 256 * 3072)
                    return zeros.withUnsafeBytes { ptr in
                        MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                    }
                }

                // inference
                guard let visionModel = model() else {
#if DEBUG
                    print("[VisionModelCoreML] model not available; returning zeroed features")
#endif
                    // return zero features of expected shape when the model isn't available
                    let zeros = [Float32](repeating: 0.0, count: 1 * 256 * 3072)
                    return zeros.withUnsafeBytes { ptr in
                        MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                    }
                }
                let output: fastvithdOutput
                do {
                    output = try visionModel.prediction(images: array)
                } catch {
#if DEBUG
                    print("[VisionModelCoreML] model prediction failed: \(error)")
#endif
                    let zeros = [Float32](repeating: 0.0, count: 1 * 256 * 3072)
                    return zeros.withUnsafeBytes { ptr in
                        MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                    }
                }
                guard output.image_features.shape == [1, 256, 3072], output.image_features.dataType == .float32 else {
                    #if DEBUG
                    print("[VisionModelCoreML] unexpected output shape or dtype: \(output.image_features.shape), dtype: \(output.image_features.dataType)")
                    #endif
                    let zeros = [Float32](repeating: 0.0, count: 1 * 256 * 3072)
                    return zeros.withUnsafeBytes { ptr in
                        MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                    }
                }
                return output.image_features.withUnsafeBytes { ptr in
                    MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                }
            }
        }
    }

    fileprivate class VisionModel: Module {

        // Create the coreml wrapper in a nonisolated initializer — the underlying
        // coreml model load will be done lazily and protected with a lock.
        nonisolated let model = VisionModelCoreML()

        // The base Module's init appears to be nonisolated in this compilation context,
        // so explicitly match it here.
        public nonisolated override init() { super.init() }

        public func callAsFunction(_ hiddenStates: MLXArray, gridThw: [THW]) -> MLXArray {
            model.encode(hiddenStates)
        }
    }
}

// MARK: - Processor

/// FastVLM `UserInputProcessor`.
///
/// This is meant to be used with ``FastVLM`` and is typically created by ``VLMModelFactory``.
public class FastVLMProcessor: UserInputProcessor {

    private let config: FastVLMProcessorConfiguration
    private let imageProcessingConfig: FastVLMPreProcessorConfiguration
    private let tokenizer: any Tokenizer

    public init(_ config: FastVLMPreProcessorConfiguration, tokenizer: any Tokenizer) {
        self.config = FastVLMProcessorConfiguration()
        self.imageProcessingConfig = config
        self.tokenizer = tokenizer
    }

    public func preprocess(image: CIImage, processing: UserInput.Processing?) throws -> (
        MLXArray, THW
    ) {
        // first apply the user requested resizing, etc. if any
        var image = MediaProcessingExtensions.apply(image, processing: processing)

        // image_processing_clip.py
        let size = MediaProcessingExtensions.fitIn(
            image.extent.size, shortestEdge: imageProcessingConfig.size.shortestEdge)
        image = MediaProcessingExtensions.resampleBicubic(image, to: size)

        image = MediaProcessingExtensions.centerCrop(
            image, size: imageProcessingConfig.cropSize.size)

        image = MediaProcessing.normalize(
            image, mean: imageProcessingConfig.imageMeanTuple,
            std: imageProcessingConfig.imageStdTuple)

        let array = MediaProcessingExtensions.asPlanarMLXArray(image)
        return (array, .init(0, array.dim(2), array.dim(3)))
    }

    public func prepare(prompt: UserInput.Prompt, imageTHW: THW?) -> String {
        // New API: `UserInput.Prompt` may be an enum with `.text(String)`.
        // Fallback: if it provides `asMessages()`, use that; otherwise, coerce to a single-text message.
        var messages: [[String: String]]
        if case let .text(text) = prompt {
            messages = [["role": "user", "content": text]]
        } else if let messagesFromPrompt = (prompt as AnyObject).value(forKey: "messages") as? [[String: String]] {
            messages = messagesFromPrompt
        } else if let asMessages = (prompt as AnyObject).perform(Selector(("asMessages")))?.takeUnretainedValue() as? [[String: String]] {
            messages = asMessages
        } else {
            messages = [["role": "user", "content": String(describing: prompt)]]
        }
        if messages[0]["role"] != "system" {
            messages.insert(["role": "system", "content": "You are a helpful assistant."], at: 0)
        }

        let lastIndex = messages.count - 1
        var lastMessage = messages[lastIndex]["content"] ?? ""

        // processing_llava.py
        if let imageTHW {
            let height = imageTHW.h
            let width = imageTHW.w
            let patchSize = config.patchSize

            var numImageTokens =
                (height / patchSize) * (width / patchSize) + config.numAdditionalImageTokens

            if config.visionFeatureSelectStrategy == .default {
                numImageTokens -= 1
            }

            lastMessage += Array(repeating: config.imageToken, count: numImageTokens)
                .joined()
        }

        messages[lastIndex]["content"] = lastMessage

        return
            messages
            .map {
                "<|im_start|>\($0["role"] ?? "user")\n\($0["content"] ?? "")<|im_end|>"
            }
            .joined(separator: "\n")
            + "\n<|im_start|>assistant\n"
    }

    public func prepare(input: UserInput) throws -> LMInput {
        if input.images.isEmpty {
            // just a straight text prompt
            let prompt = prepare(prompt: input.prompt, imageTHW: nil)
            let promptTokens = tokenizer.encode(text: prompt)
            return LMInput(tokens: MLXArray(promptTokens))
        }

        if input.images.count > 1 {
            throw VLMError.singleImageAllowed
        }

        let (pixels, thw) = try preprocess(
            image: input.images[0].asCIImage(), processing: input.processing)
        let image = LMInput.ProcessedImage(pixels: pixels)

        let prompt = prepare(prompt: input.prompt, imageTHW: thw)
        let promptTokens = tokenizer.encode(text: prompt)
        let promptArray = MLXArray(promptTokens).expandedDimensions(axis: 0)
        let mask = ones(like: promptArray).asType(.int8)

        return LMInput(text: .init(tokens: promptArray, mask: mask), image: image)
    }

}

// MARK: - Model



    fileprivate class FastVLMMultiModalProjector: Module, UnaryLayer {

    @ModuleInfo(key: "linear_0") var linear0: Linear
    @ModuleInfo(key: "gelu") var gelu: GELU
    @ModuleInfo(key: "linear_2") var linear2: Linear


    public init(_ config: FastVLMConfiguration) {
        self._linear0.wrappedValue = Linear(
            config.visionConfiguration.hiddenSize,
            config.textConfiguration.hiddenSize,
            bias: true)
        self._gelu.wrappedValue = GELU()
        self._linear2.wrappedValue = Linear(
            config.textConfiguration.hiddenSize,
            config.textConfiguration.hiddenSize,
            bias: true)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = linear0(x)
        x = gelu(x)
        x = linear2(x)
        return x
    }
}

/// FastVLM
///
/// This is typically created by ``VLMModelFactory``.
    public class FastVLM: Module, VLMModel, KVCacheDimensionProvider {

    static public var modelConfiguration: ModelConfiguration {
        let bundle = Bundle(for: FastVLM.self)
        let url: URL
        if let confUrl = bundle.url(forResource: "config", withExtension: "json") {
            url = confUrl.resolvingSymlinksInPath().deletingLastPathComponent()
        } else if let mainUrl = Bundle.main.url(forResource: "config", withExtension: "json") {
            url = mainUrl.resolvingSymlinksInPath().deletingLastPathComponent()
        } else {
#if DEBUG
            print("[FastVLM.modelConfiguration] config.json not found in module or main bundle; using bundle resource URL or current directory")
#endif
            url = bundle.resourceURL ?? URL(fileURLWithPath: ".")
        }
        return ModelConfiguration(directory: url)
    }

    static public func register(modelFactory: VLMModelFactory) {
        modelFactory.typeRegistry.registerModelType("llava_qwen2") { url in
            let configuration = try JSONDecoder().decode(
                FastVLMConfiguration.self, from: Data(contentsOf: url))
            return FastVLM(configuration)
        }

        modelFactory.processorRegistry.registerProcessorType("LlavaProcessor") { url, tokenizer in
            let configuration = try JSONDecoder().decode(
                FastVLMPreProcessorConfiguration.self, from: Data(contentsOf: url))
            return FastVLMProcessor(configuration, tokenizer: tokenizer)
        }
    }

    @ModuleInfo(key: "vision_tower") private var visionModel: Vision.VisionModel
    @ModuleInfo(key: "language_model") private var languageModel: Language.LanguageModel
    @ModuleInfo(key: "multi_modal_projector") private var multiModalProjector:
        FastVLMMultiModalProjector

    public let config: FastVLMConfiguration

    public var vocabularySize: Int { config.baseConfiguration.vocabularySize }
    public var kvHeads: [Int] { languageModel.kvHeads }

    public func loraLinearLayers() -> MLXLMCommon.LoRALinearLayers {
        languageModel.model.layers.map { ($0.attention, ["q_proj", "v_proj"]) }
    }


    public init(_ config: FastVLMConfiguration) {
        self.config = config
        self._visionModel.wrappedValue = Vision.VisionModel()
        self._languageModel.wrappedValue = Language.LanguageModel(config.textConfiguration)
        self._multiModalProjector.wrappedValue = FastVLMMultiModalProjector(config)
    }

    private func inputEmbeddings(inputIds: MLXArray, pixelValues: MLXArray?, gridThw: [THW]?)
        -> MLXArray
    {
        guard let pixelValues, let gridThw else {
            return languageModel(inputIds).logits
        }

        // Get the input embeddings from the language model
        let inputEmbeds = languageModel.model.embedTokens(inputIds)

        // Get the ouptut hidden states from the vision model
        let imageFeaturesCoreML = self.visionModel(pixelValues, gridThw: gridThw)
        let imageFeatures = multiModalProjector(imageFeaturesCoreML)

        // Insert special image tokens in the input_ids
        return mergeInputIdsWithImageFeatures(
            inputIds: inputIds, inputEmbeds: inputEmbeds, imageFeatures: imageFeatures)
    }

    private func mergeInputIdsWithImageFeatures(
        inputIds: MLXArray, inputEmbeds: MLXArray, imageFeatures: MLXArray
    ) -> MLXArray {
        let imageTokenIndex = config.baseConfiguration.imageTokenId

        var imageIndices = [Int]()
        for (i, v) in inputIds.asArray(Int.self).enumerated() {
            if v == imageTokenIndex {
                imageIndices.append(i)
            }
        }

        inputEmbeds[0..., MLXArray(imageIndices), 0...] = imageFeatures
        return inputEmbeds
    }

    public func prepare(_ input: LMInput, cache: [any KVCache], windowSize: Int?) throws
        -> PrepareResult
    {
        let dtype = DType.float32
        let pixels = input.image?.pixels.asType(dtype)
        let gridThw: [THW]?
        if let px = pixels {
            gridThw = [THW(0, px.dim(2), px.dim(3))]
        } else {
            gridThw = nil
        }

        let inputEmbeddings = self.inputEmbeddings(
            inputIds: input.text.tokens, pixelValues: pixels, gridThw: gridThw)

        let result = languageModel(nil, cache: cache, inputEmbedding: inputEmbeddings)

        return .logits(result)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [any KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache).logits
    }

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        // Ensure the underlying CoreML model is loaded, if available.
        _ = try? visionModel.model.load()

        return weights
    }
}



// MARK: - Non-isolated adapters

/// Adapter that allows returning a VLMModel instance from a nonisolated
/// registration closure. It forwards calls to the underlying @MainActor
/// `FastVLM` instance by executing code on the MainActor and blocking until
/// the result is available. This avoids exposing MainActor-isolated types
/// to non-isolated callers while preserving synchronous APIs required by the
/// registry.
// Removed wrapper; implementations are not necessary when returning the actual FastVLM
// NOTE: removed NonisolatedFastVLM implementation

/// Adapter for `UserInputProcessor` so a nonisolated closure may return a
/// processor instance while the underlying `FastVLMProcessor` may be
/// actor-isolated.
// NOTE: removed NonisolatedFastVLMProcessor implementation

// MARK: - Configuration

/// Configuration for ``FastVLM``
public struct FastVLMConfiguration: Codable, Sendable {

    public struct VisionConfiguration: Codable, Sendable {
        public let hiddenSize: Int

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "mm_hidden_size"
        }

        public init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        }
    }

    public struct TextConfiguration: Codable, Sendable {
        public let modelType: String
        public let hiddenSize: Int
        public let hiddenLayers: Int
        public let intermediateSize: Int
        public let attentionHeads: Int
        private let _rmsNormEps: Float?
        public var rmsNormEps: Float { _rmsNormEps ?? 1e-6 }
        public let vocabularySize: Int
        public let kvHeads: Int
        private let _maxPositionEmbeddings: Int?
        public var maxpPositionEmbeddings: Int { _maxPositionEmbeddings ?? 32768 }
        private let _ropeTheta: Float?
        public var ropeTheta: Float { _ropeTheta ?? 1_000_000 }
        private let _ropeTraditional: Bool?
        public var ropeTraditional: Bool { _ropeTraditional ?? false }
        public let _ropeScaling: [String: StringOrNumber]?
        public var ropeScaling: [String: StringOrNumber]? {
            _ropeScaling ?? ["mrope_section": .ints([2, 1, 1])]
        }
        private let _tieWordEmbeddings: Bool?
        public var tieWordEmbeddings: Bool { _tieWordEmbeddings ?? true }

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case hiddenSize = "hidden_size"
            case hiddenLayers = "num_hidden_layers"
            case intermediateSize = "intermediate_size"
            case attentionHeads = "num_attention_heads"
            case _rmsNormEps = "rms_norm_eps"
            case vocabularySize = "vocab_size"
            case kvHeads = "num_key_value_heads"
            case _maxPositionEmbeddings = "max_position_embeddings"
            case _ropeTheta = "rope_theta"
            case _ropeTraditional = "rope_traditional"
            case _ropeScaling = "rope_scaling"
            case _tieWordEmbeddings = "tie_word_embeddings"
            }
            public init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.modelType = try container.decode(String.self, forKey: .modelType)
            self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
            self.hiddenLayers = try container.decode(Int.self, forKey: .hiddenLayers)
            self.intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
            self.attentionHeads = try container.decode(Int.self, forKey: .attentionHeads)
            self._rmsNormEps = try container.decodeIfPresent(Float.self, forKey: ._rmsNormEps)
            self.vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
            self.kvHeads = try container.decode(Int.self, forKey: .kvHeads)
            self._maxPositionEmbeddings = try container.decodeIfPresent(Int.self, forKey: ._maxPositionEmbeddings)
            self._ropeTheta = try container.decodeIfPresent(Float.self, forKey: ._ropeTheta)
            self._ropeTraditional = try container.decodeIfPresent(Bool.self, forKey: ._ropeTraditional)
            self._ropeScaling = try container.decodeIfPresent([String: StringOrNumber].self, forKey: ._ropeScaling)
            self._tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: ._tieWordEmbeddings)
        }
    }

    public struct BaseConfiguration: Codable, Sendable {
        public let modelType: String
        public let vocabularySize: Int
        public let imageTokenId: Int
        public let hiddenSize: Int

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case vocabularySize = "vocab_size"
            case imageTokenId = "image_token_index"
            case hiddenSize = "hidden_size"
            }
            public init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.modelType = try container.decode(String.self, forKey: .modelType)
            self.vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
            self.imageTokenId = try container.decode(Int.self, forKey: .imageTokenId)
            self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        }
    }

    public let visionConfiguration: VisionConfiguration
    public let textConfiguration: TextConfiguration
    public let baseConfiguration: BaseConfiguration

    public init(from decoder: any Swift.Decoder) throws {
        // these are overlaid in the top level
        self.visionConfiguration = try VisionConfiguration(from: decoder)
        self.textConfiguration = try TextConfiguration(from: decoder)
        self.baseConfiguration = try BaseConfiguration(from: decoder)
    }
}

/// Configuration for ``FastVLMProcessor``
public struct FastVLMPreProcessorConfiguration: Codable, Sendable {

    public struct CropSize: Codable, Sendable {
        let width: Int
        let height: Int

        var size: CGSize { .init(width: CGFloat(width), height: CGFloat(height)) }
    }

    public struct Size: Codable, Sendable {
        let shortestEdge: Int

        enum CodingKeys: String, CodingKey {
            case shortestEdge = "shortest_edge"
        }
    }

    public var imageMean: [CGFloat]
    public var imageStd: [CGFloat]
    public var size: Size
    public var cropSize: CropSize

    public var imageMeanTuple: (CGFloat, CGFloat, CGFloat) {
        (imageMean[0], imageMean[1], imageMean[2])
    }
    public var imageStdTuple: (CGFloat, CGFloat, CGFloat) {
        (imageStd[0], imageStd[1], imageStd[2])
    }

    enum CodingKeys: String, CodingKey {
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case size
        case cropSize = "crop_size"
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageMean = try container.decode([CGFloat].self, forKey: .imageMean)
        imageStd = try container.decode([CGFloat].self, forKey: .imageStd)
        size = try container.decode(Size.self, forKey: .size)
        cropSize = try container.decode(CropSize.self, forKey: .cropSize)
    }
}

public struct FastVLMProcessorConfiguration: Codable, Sendable {

    public enum Strategy: Codable, Sendable {
        case `default`
    }

    public var imageToken = "<image>"
    public var numAdditionalImageTokens = 0
    public var patchSize = 64
    public var visionFeatureSelectStrategy: Strategy?

}
