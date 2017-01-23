Shader "Hidden/HDRenderPipeline/Deferred"
{
    Properties
    {
        // We need to be able to control the blend mode for deferred shader in case we do multiple pass
        _SrcBlend("", Float) = 1
        _DstBlend("", Float) = 1

        _StencilRef("_StencilRef", Int) = 0
    }

    SubShader
    {

        Pass
        {

            /* TODO-READ_DEPTH-TEST_STENCIL
             * In Unity, it is currently not possible to perform the stencil test while at the same time
             * reading from the depth texture in the shader. It is legal in Direct3D.
             * Therefore, we are forced to split lighting using MRT for all materials.

            Stencil
            {
                Ref  [_StencilRef]
                Comp Equal
                Pass Keep
            }
            */

            ZWrite Off
            ZTest  Always
            Blend [_SrcBlend][_DstBlend]

            HLSLPROGRAM
            #pragma target 4.5
            #pragma only_renderers d3d11 ps4 metal // TEMP: unitl we go futher in dev

            #pragma vertex Vert
            #pragma fragment Frag

            // Chose supported lighting architecture in case of deferred rendering
            #pragma multi_compile LIGHTLOOP_SINGLE_PASS LIGHTLOOP_TILE_PASS
            //#pragma multi_compile SHADOWFILTERING_FIXED_SIZE_PCF

            // TODO: Workflow problem here, I would like to only generate variant for the LIGHTLOOP_TILE_PASS case, not the LIGHTLOOP_SINGLE_PASS case. This must be on lightloop side and include here.... (Can we codition
            #pragma multi_compile LIGHTLOOP_TILE_DIRECT LIGHTLOOP_TILE_INDIRECT LIGHTLOOP_TILE_ALL
            #pragma multi_compile USE_FPTL_LIGHTLIST USE_CLUSTERED_LIGHTLIST

            // Split lighting is utilized during the SSS pass.
            #pragma multi_compile _ OUTPUT_SPLIT_LIGHTING

            //-------------------------------------------------------------------------------------
            // Include
            //-------------------------------------------------------------------------------------

            #include "Common.hlsl"

            // Note: We have fix as guidelines that we have only one deferred material (with control of GBuffer enabled). Mean a users that add a new
            // deferred material must replace the old one here. If in the future we want to support multiple layout (cause a lot of consistency problem),
            // the deferred shader will require to use multicompile.
            #define UNITY_MATERIAL_LIT // Need to be define before including Material.hlsl
            #include "Assets/ScriptableRenderLoop/HDRenderPipeline/ShaderConfig.cs.hlsl"
            #include "Assets/ScriptableRenderLoop/HDRenderPipeline/ShaderVariables.hlsl"
            #include "Assets/ScriptableRenderLoop/HDRenderPipeline/Lighting/Lighting.hlsl" // This include Material.hlsl

            //-------------------------------------------------------------------------------------
            // variable declaration
            //-------------------------------------------------------------------------------------

            DECLARE_GBUFFER_TEXTURE(_GBufferTexture);

 			TEXTURE2D(_CameraDepthTexture);
			SAMPLER2D(sampler_CameraDepthTexture);

            struct Attributes
            {
                uint vertexId : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            struct Outputs
            {
            #ifdef OUTPUT_SPLIT_LIGHTING
            	float4 specularLighting : SV_Target0;
            	float3 diffuseLighting  : SV_Target1;
            #else
                float4 combinedLighting : SV_Target0;
            #endif
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;

                // Generate a triangle in homogeneous clip space, s.t.
			    // v0 = (-1, -1, 1), v1 = (3, -1, 1), v2 = (-1, 3, 1).
			    output.positionCS = float4(float(input.vertexId % 2) * 4.0 - 1.0,
			    						   float(input.vertexId / 2) * 4.0 - 1.0, 1.0, 1.0);
                return output;
            }

            Outputs Frag(Varyings input)
            {
                // input.positionCS is SV_Position
                PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw);
                float depth = LOAD_TEXTURE2D(_CameraDepthTexture, posInput.unPositionSS).x;
                UpdatePositionInput(depth, _InvViewProjMatrix, _ViewProjMatrix, posInput);
                float3 V = GetWorldSpaceNormalizeViewDir(posInput.positionWS);

                FETCH_GBUFFER(gbuffer, _GBufferTexture, posInput.unPositionSS);
                BSDFData bsdfData;
                float3 bakeDiffuseLighting;
                DECODE_FROM_GBUFFER(gbuffer, bsdfData, bakeDiffuseLighting);

                PreLightData preLightData = GetPreLightData(V, posInput, bsdfData);

                float3 diffuseLighting;
                float3 specularLighting;
                LightLoop(V, posInput, preLightData, bsdfData, bakeDiffuseLighting, diffuseLighting, specularLighting);

                Outputs outputs;
            #ifdef OUTPUT_SPLIT_LIGHTING
                outputs.specularLighting = float4(specularLighting, 1.0);
                outputs.diffuseLighting  = diffuseLighting;
            #else
                outputs.combinedLighting = float4(diffuseLighting + specularLighting, 1.0);
            #endif
                return outputs;
            }

        ENDHLSL
        }

    }
    Fallback Off
}
