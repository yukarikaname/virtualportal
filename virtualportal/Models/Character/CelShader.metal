//
//  CelShader.metal
//  virtualportal
//
//  Created by automated refactor.
//

#if __has_include(<RealityKit/RealityKit.h>)
#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// MARK: - Surface Shader

[[visible]]
void cel_surface(realitykit::surface_parameters params)
{
    // High quality cel shader with sophisticated lighting

    auto baseColor = params.material_constants().base_color_tint();
    auto worldNormal = params.geometry().normal();
    // Note: RealityKit surface_parameters does not provide view or lighting environment access
    // Using default values for cel shading calculations
    auto viewDirection = float3(0, 0, 1); // Default forward view direction
    auto lightDirection = float3(0, 0, -1); // Default light from above
    auto lightColor = float3(1, 1, 1); // Default white light

    // Multi-level cel shading
    float NdotL = saturate(dot(worldNormal, -lightDirection));

    // Create more nuanced shading levels
    float celShade;
    if (NdotL > 0.8) {
        celShade = 1.0;
    } else if (NdotL > 0.6) {
        celShade = 0.8;
    } else if (NdotL > 0.4) {
        celShade = 0.6;
    } else if (NdotL > 0.2) {
        celShade = 0.4;
    } else {
        celShade = 0.2;
    }

    // Base diffuse
    auto diffuseColor = baseColor * celShade * lightColor;

    // Enhanced rim lighting
    float rimFactor = 1.0 - saturate(dot(viewDirection, worldNormal));
    rimFactor = smoothstep(0.6, 1.0, rimFactor); // Softer rim transition
    auto rimColor = lightColor * rimFactor * 0.4;

    // Anisotropic specular for hair-like materials
    float3 tangent = cross(worldNormal, float3(1.0, 0.0, 0.0));
    if (length(tangent) < 0.1) {
        tangent = cross(worldNormal, float3(0.0, 1.0, 0.0));
    }
    tangent = normalize(tangent);

    float3 anisotropicDir = normalize(tangent + worldNormal * 0.5);
    float anisoSpec = pow(saturate(dot(viewDirection, anisotropicDir)), 8.0);

    // Fresnel effect for material interaction
    float fresnel = pow(1.0 - saturate(dot(viewDirection, worldNormal)), 2.0);
    auto fresnelColor = lightColor * fresnel * 0.2;

    // Combine all effects
    auto finalColor = diffuseColor + rimColor + fresnelColor;
    finalColor += float3(anisoSpec * 0.3, anisoSpec * 0.3, anisoSpec * 0.3);

    // Subtle emissive glow on very bright areas
    if (celShade > 0.9) {
        params.surface().set_emissive_color(half3(finalColor * 0.05));
    }

    params.surface().set_base_color(half3(saturate(finalColor)));
}
#endif
