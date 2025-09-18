//
//  KBDLogging.swift
//  UnsaidKeyboard
//
//  Shared logging utilities for the keyboard extension
//

import Foundation
import os.log
import QuartzCore

// MARK: - Unified Logging System
enum LogLevel { case info, debug, warn, error }

#if DEBUG
@inline(__always)
func KBDLog(_ msg: @autoclosure () -> String, _ level: LogLevel = .debug, _ cat: String = "General") {
    struct L {
        static var loggers: [String: Logger] = [:]
        static func logger(_ cat: String) -> Logger {
            if let l = loggers[cat] { return l }
            let l = Logger(subsystem: "com.example.unsaid.UnsaidKeyboard", category: cat)
            loggers[cat] = l; return l
        }
    }
    let text = msg()
    let logger = L.logger(cat)
    switch level {
    case .info:  logger.info("\(text)")
    case .debug: logger.debug("\(text)")
    case .warn:  logger.warning("\(text)")
    case .error: logger.error("\(text)")
    }
}
#else
@inline(__always) func KBDLog(_ : @autoclosure () -> String, _ : LogLevel = .debug, _ : String = "General") {}
#endif

// MARK: - Log De-duper
#if DEBUG
final class LogGate {
    private var last: [String:(t: CFTimeInterval, msg: String)] = [:]
    private let minGap: CFTimeInterval
    init(_ minGap: CFTimeInterval = 0.40) { self.minGap = minGap }
    func allow(_ key: String, _ message: String) -> Bool {
        let now = CACurrentMediaTime()
        if let p = last[key], now - p.t < minGap, p.msg == message { return false }
        last[key] = (now, message); return true
    }
}
#endif