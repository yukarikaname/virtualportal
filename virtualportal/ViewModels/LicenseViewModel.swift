//
//  LicenseViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 8/20/25.
//

import Foundation
import SwiftUI
import Combine

public struct Library: Identifiable {
    public let id = UUID()
    public let name: String
    public let licenseName: String
    public let licenseText: String

    public init(name: String, licenseName: String, licenseText: String) {
        self.name = name
        self.licenseName = licenseName
        self.licenseText = licenseText
    }
}

@MainActor
public final class LicenseViewModel: ObservableObject {
    @Published public private(set) var libraries: [Library] = []

    public init() {
        loadDefaultLibraries()
    }

    private func loadDefaultLibraries() {
        // Keep the static list here to centralize license data
        self.libraries = [
            Library(
                name: "MLX Swift",
                licenseName: "MIT license",
                licenseText: """
                MIT License

                Copyright (c) 2023 ml-explore

                Permission is hereby granted, free of charge, to any person obtaining a copy
                of this software and associated documentation files (the "Software"), to deal
                in the Software without restriction, including without limitation the rights
                to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                copies of the Software, and to permit persons to whom the Software is
                furnished to do so, subject to the following conditions:

                The above copyright notice and this permission notice shall be included in all
                copies or substantial portions of the Software.

                THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
                SOFTWARE.
                """
            ),
            Library(
                name: "MLX Swift Examples",
                licenseName: "MIT license",
                licenseText: """
                MIT License

                Copyright (c) 2024 ml-explore

                Permission is hereby granted, free of charge, to any person obtaining a copy
                of this software and associated documentation files (the "Software"), to deal
                in the Software without restriction, including without limitation the rights
                to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                copies of the Software, and to permit persons to whom the Software is
                furnished to do so, subject to the following conditions:

                The above copyright notice and this permission notice shall be included in all
                copies or substantial portions of the Software.

                THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
                SOFTWARE.
                """
            ),
            Library(
                name: "Swift Transformers",
                licenseName: "Apache-2.0 license",
                licenseText: """
                Apache License
                Version 2.0, January 2004
                http://www.apache.org/licenses/

                TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION
                
                1. Definitions.

                  "License" shall mean the terms and conditions for use, reproduction,
                  and distribution as defined by Sections 1 through 9 of this document.

                  "Licensor" shall mean the copyright owner or entity authorized by
                  the copyright owner that is granting the License.

                  "Legal Entity" shall mean the union of the acting entity and all
                  other entities that control, are controlled by, or are under common
                  control with that entity. For the purposes of this definition,
                  "control" means (i) the power, direct or indirect, to cause the
                  direction or management of such entity, whether by contract or
                  otherwise, or (ii) ownership of fifty percent (50%) or more of the
                  outstanding shares, or (iii) beneficial ownership of such entity.

                  "You" (or "Your") shall mean an individual or Legal Entity
                  exercising permissions granted by this License.

                  "Source" form shall mean the preferred form for making modifications,
                  including but not limited to software source code, documentation
                  source, and configuration files.

                  "Object" form shall mean any form resulting from mechanical
                  transformation or translation of a Source form, including but
                  not limited to compiled object code, generated documentation, and
                  conversions to other media types.

                  "Work" shall mean the work of authorship, whether in Source or
                  Object form, made available under the License, as indicated by a
                  copyright notice that is included in or attached to the work
                  (an example is provided in the Appendix below).

                  "Derivative Works" shall mean any work, whether in Source or Object
                  form, that is based on (or derived from) the Work and for which the
                  editorial revisions, annotations, elaborations, or other modifications
                  represent, as a whole, an original work of authorship. For the purposes
                  of this License, Derivative Works shall not include works that remain
                  separable from, or merely link (or bind by name) to the interfaces of,
                  the Work and Derivative Works thereof.

                  "Contribution" shall mean any work of authorship, including
                  the original version of the Work and any modifications or additions
                  to that Work or Derivative Works thereof, that is intentionally
                  submitted to Licensor for inclusion in the Work by the copyright owner
                  or by an individual or Legal Entity authorized to submit on behalf of
                  the copyright owner. For the purposes of this definition, "submitted"
                  means any form of electronic, verbal, or written communication sent
                  to the Licensor or its representatives, including but not limited to
                  communication on electronic mailing lists, source code control systems,
                  and issue tracking systems that are managed by, or on behalf of, the
                  Licensor for the purpose of discussing and improving the Work, but
                  excluding communication that is conspicuously marked or otherwise
                  designated in writing by the copyright owner as "Not a Contribution."
                """
            ),
            Library(
                name: "FastVLM (App)",
                licenseName: "FastVLM license",
                licenseText: """
                Copyright (C) 2025 Apple Inc. All Rights Reserved.

                IMPORTANT:  This Apple software is supplied to you by Apple
                Inc. ("Apple") in consideration of your agreement to the following
                terms, and your use, installation, modification or redistribution of
                this Apple software constitutes acceptance of these terms.  If you do
                not agree with these terms, please do not use, install, modify or
                redistribute this Apple software.

                In consideration of your agreement to abide by the following terms, and
                subject to these terms, Apple grants you a personal, non-exclusive
                license, under Apple's copyrights in this original Apple software (the
                "Apple Software"), to use, reproduce, modify and redistribute the Apple
                Software, with or without modifications, in source and/or binary forms;
                provided that if you redistribute the Apple Software in its entirety and
                without modifications, you must retain this notice and the following
                text and disclaimers in all such redistributions of the Apple Software.
                Neither the name, trademarks, service marks or logos of Apple Inc. may
                be used to endorse or promote products derived from the Apple Software
                without specific prior written permission from Apple.  Except as
                expressly stated in this notice, no other rights or licenses are
                granted by Apple herein, including but not limited to any
                patent rights that may be infringed by your derivative works or by other
                works in which the Apple Software may be incorporated.
                """
            ),
            Library(
                name: "FastVLM (Model)",
                licenseName: "FastVLM Model license",
                licenseText: """
                Disclaimer: IMPORTANT: This Apple Machine Learning Research Model is
                specifically developed and released by Apple Inc. ("Apple") for the sole purpose
                of scientific research of artificial intelligence and machine-learning
                technology. “Apple Machine Learning Research Model” means the model, including
                but not limited to algorithms, formulas, trained model weights, parameters,
                configurations, checkpoints, and any related materials (including
                documentation).
                """
            )
        ]
    }
}
