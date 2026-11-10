require "log"

module CrystKit::Platform::Windows
  module Printing
    extend self

    Log = ::Log.for(self)

    # WebView2 print via ShowPrintUI (COM dispatch)
    # ICoreWebView2_6 vtable index 72 = ShowPrintUIAsync
    private def self.make_proc(fn_ptr : Void*, type : T.class) : T forall T
      storage = uninitialized UInt64[2]
      storage[0] = fn_ptr.address
      storage[1] = 0_u64
      storage.to_unsafe.as(Pointer(T)).value
    end

    def self.print(wv : Void*, options) : Bool
      return false if wv.null?
      com_obj = wv.as(Pointer(Pointer(Void)))
      vtable = com_obj.value
      show_print_ui = vtable.as(Pointer(Pointer(Void)))[72]
      fn = make_proc(show_print_ui, Proc(Void*, Void*, Int32))
      fn.call(wv, Pointer(Void).new(0_u64)) >= 0
    rescue ex
      Log.error { "Windows print failed: #{ex.message}" }
      false
    end

    # WebView2 print to PDF via PrintToPdfAsync (COM dispatch)
    # ICoreWebView2_6 vtable index 73 = PrintToPdfAsync
    def self.print_to_pdf(wv : Void*, output : String, options) : Bool
      return false if wv.null?
      com_obj = wv.as(Pointer(Pointer(Void)))
      vtable = com_obj.value
      print_to_pdf = vtable.as(Pointer(Pointer(Void)))[73]
      fn = make_proc(print_to_pdf, Proc(Void*, Void*, Void*, Void*, Int32))

      output_ptr = output.to_unsafe
      hr = fn.call(wv, output_ptr.as(Void*), Pointer(Void).new(0_u64), Pointer(Void).new(0_u64))
      hr >= 0
    rescue ex
      Log.error { "Windows print to PDF failed: #{ex.message}" }
      false
    end

    def self.list_printers : Array(String)
      # Windows printer enumeration requires WinSpool
      ["Default Printer"]
    rescue
      [] of String
    end

    def self.show_dialog(wv : Void*, options) : Bool
      # Same as print() — ShowPrintUIAsync shows the native dialog
      print(wv, options)
    end
  end
end
