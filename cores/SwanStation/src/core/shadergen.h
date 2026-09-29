#pragma once
#include "gpu_hw.h"
#include "host_display.h"
#include <sstream>
#include <string>
#include <vector>

/// The names the Metal backend looks the two entry points up by. Every Metal
/// shader this core generates defines both, so they only have to be stable.
extern const char* const METAL_VERTEX_FUNCTION_NAME;
extern const char* const METAL_FRAGMENT_FUNCTION_NAME;

class ShaderGen
{
public:
  ShaderGen(HostDisplay::RenderAPI render_api, bool supports_dual_source_blend);
  ~ShaderGen();

  static bool UseGLSLBindingLayout();

  std::string GenerateScreenQuadVertexShader();
  std::string GenerateUVQuadVertexShader();
  std::string GenerateCopyFragmentShader();

  /// Closes the function the Metal entry point declaration opened. The
  /// generators emit the entry point declaration followed by the body as a
  /// complete block, and MSL entry points return the struct the body filled
  /// in, so the caller (the Metal shader cache) appends the ending.
  static std::string FinalizeMetalShader(std::string shader);

protected:
  ALWAYS_INLINE bool IsVulkan() const { return (m_render_api == HostDisplay::RenderAPI::Vulkan); }
  ALWAYS_INLINE bool IsMetal() const { return (m_render_api == HostDisplay::RenderAPI::Metal); }
  ALWAYS_INLINE bool IsGLSL() const { return m_glsl; }

  const char* GetInterpolationQualifier(bool interface_block, bool centroid_interpolation, bool sample_interpolation,
                                        bool is_out) const;

  void SetGLSLVersionString();
  void DefineMacro(std::stringstream& ss, const char* name, bool enabled);
  void WriteHeader(std::stringstream& ss);
  void WriteUniformBufferDeclaration(std::stringstream& ss, bool push_constant_on_vulkan);
  void DeclareUniformBuffer(std::stringstream& ss, const std::initializer_list<const char*>& members,
                            bool push_constant_on_vulkan);
  void DeclareTexture(std::stringstream& ss, const char* name, uint32_t index, bool multisampled = false);
  void DeclareTextureBuffer(std::stringstream& ss, const char* name, uint32_t index, bool is_int, bool is_unsigned);
  void DeclareVertexEntryPoint(std::stringstream& ss, const std::initializer_list<const char*>& attributes,
                               uint32_t num_color_outputs, uint32_t num_texcoord_outputs,
                               const std::initializer_list<std::pair<const char*, const char*>>& additional_outputs,
                               bool declare_vertex_id = false, const char* output_block_suffix = "", bool msaa = false,
                               bool ssaa = false, bool noperspective_color = false);
  void DeclareFragmentEntryPoint(std::stringstream& ss, uint32_t num_color_inputs, uint32_t num_texcoord_inputs,
                                 const std::initializer_list<std::pair<const char*, const char*>>& additional_inputs,
                                 bool declare_fragcoord = false, uint32_t num_color_outputs = 1, bool depth_output = false,
                                 bool msaa = false, bool ssaa = false, bool declare_sample_id = false,
                                 bool noperspective_color = false);

  /// Metal declarations.
  ///
  /// MSL has no global resources: uniforms, textures and samplers are entry
  /// point parameters, and the body writes into a struct the entry point
  /// returns. The shader bodies are one dialect shared with GLSL and HLSL, so
  /// the declarations above cannot be emitted where the generators call them.
  /// Instead the resources are remembered here and the entry point declaration
  /// emits them, and the generator's caller appends FinalizeMetalShader() to
  /// close the function (the body is a complete block the generators emit
  /// after the entry point).
  struct MetalTextureResource
  {
    const char* name;
    uint32_t index;
    bool multisampled;
  };

  struct MetalTextureBufferResource
  {
    const char* name;
    uint32_t index;
  };

  static constexpr uint32_t METAL_UNIFORM_BUFFER_INDEX = 1;
  static constexpr uint32_t METAL_TEXTURE_BUFFER_INDEX = 2;

  void ResetMetalResources();
  void WriteMetalResourceParameters(std::stringstream& ss) const;

  HostDisplay::RenderAPI m_render_api;
  bool m_glsl;
  bool m_supports_dual_source_blend;
  bool m_use_glsl_interface_blocks;
  bool m_use_glsl_binding_layout;
  bool m_metal_uniform_buffer_declared = false;
  std::vector<MetalTextureResource> m_metal_textures;
  std::vector<MetalTextureBufferResource> m_metal_texture_buffers;

  std::string m_glsl_version_string;
};
