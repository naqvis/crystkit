require "log"
require "./objc_runtime"

module CrystKit
  module Platform
    module MacOS
      module Printing
        Log = ::Log.for(self)

        # Shared helper: create an NSPrintOperation from WKWebView's instance
        # method and run it. This is the documented macOS API for printing web
        # content.
        private def self.run_print_operation(wv : Void*) : Bool
          print_info = ObjCRuntime.msg(ObjCRuntime.get_class("NSPrintInfo"), "sharedPrintInfo")
          print_op = ObjCRuntime.msg(wv, "printOperationWithPrintInfo:", print_info)
          ObjCRuntime.msg(print_op, "runOperation")
          true
        end

        # Print by showing the native print dialog via NSPrintOperation.
        def self.print(wv : Void*, options) : Bool
          pool = LibObjC.objc_autoreleasePoolPush
          result = run_print_operation(wv)
          LibObjC.objc_autoreleasePoolPop(pool)
          result
        rescue ex
          Log.error { "Print failed" }
          false
        end

        # Print to PDF by showing the print dialog with shared print info.
        # The user can select "Save as PDF" from the dialog.
        def self.print_to_pdf(wv : Void*, output : String, options) : Bool
          pool = LibObjC.objc_autoreleasePoolPush
          result = run_print_operation(wv)
          LibObjC.objc_autoreleasePoolPop(pool)
          result
        rescue ex
          Log.error { "Print to PDF failed" }
          false
        end

        def self.list_printers : Array(String)
          pool = LibObjC.objc_autoreleasePoolPush
          ns_printer = ObjCRuntime.get_class("NSPrinter")
          names_array = ObjCRuntime.msg(ns_printer, "printerNames")
          count = ObjCRuntime.msg_long(names_array, "count")
          names = [] of String
          count.times do |i|
            name_str = ObjCRuntime.msg_object_at(names_array, "objectAtIndex:", i.to_u64)
            name = ObjCRuntime.nsstring_to_s(name_str)
            names << (name || "unknown")
          end
          LibObjC.objc_autoreleasePoolPop(pool)
          names
        rescue ex
          Log.error { "List printers failed" }
          [] of String
        end

        # Show the native print dialog via NSPrintOperation.
        def self.show_dialog(wv : Void*, options) : Bool
          pool = LibObjC.objc_autoreleasePoolPush
          result = run_print_operation(wv)
          LibObjC.objc_autoreleasePoolPop(pool)
          result
        rescue ex
          Log.error { "Print dialog failed" }
          false
        end
      end
    end
  end
end
