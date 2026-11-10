require "log"
require "../../core/errors"
require "./init"

module CrystKit::Platform::MacOS::CustomProtocol
  extend self

  LOG = ::Log.for("CustomProtocol[macOS]")

  @[Link(ldflags: "#{__DIR__}/custom_protocol_setup.mm -framework WebKit -framework Foundation")]
  lib LibCrystKitCustomProtocol
    fun crystkit_install_scheme_handler(scheme : LibC::Char*) : Void
    fun crystkit_set_url_resolver(resolver : Void*) : Void
  end

  @@resolver : Proc(String, {Bytes, String}?)?

  def setup(scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil
    Init.ensure_app
    @@resolver = resolver

    callback = ->(url_cstr : LibC::Char*, body_out : Pointer(LibC::Char*), body_len : Pointer(LibC::Int), mime_out : Pointer(LibC::Char*)) {
      if r = @@resolver
        result = r.call(String.new(url_cstr))
        if result
          bytes, mime_str = result
          body_out.value = bytes.to_unsafe.as(LibC::Char*)
          body_len.value = bytes.size.to_i32
          mime_out.value = mime_str.to_unsafe.as(LibC::Char*)
        end
      end
    }

    LibCrystKitCustomProtocol.crystkit_set_url_resolver(callback.pointer)
    LibCrystKitCustomProtocol.crystkit_install_scheme_handler(scheme.to_unsafe)

    Log.info { "CustomProtocol[macOS]: installed swizzle for #{scheme}://" }
  end

  def register(wv : T, scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil forall T
  end
end
