//
//  StreamingSession.swift
//  
//
//  Created by Sergii Kryvoblotskyi on 18/04/2023.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StreamingSession<ResultType: Codable>: NSObject, Identifiable, URLSessionDelegate, URLSessionDataDelegate {
    
    enum StreamingError: Error {
        case unknownContent
        case emptyContent
        case apiError(APIErrorResponse)
    }
    
    var onReceiveContent: ((StreamingSession, ResultType) -> Void)?
    var onProcessingError: ((StreamingSession, Error) -> Void)?
    var onComplete: ((StreamingSession, Error?) -> Void)?
    var onComment: ((StreamingSession, String) -> Void)? // Optional callback for comments
    
    private let streamingCompletionMarker = "[DONE]"
    private let urlRequest: URLRequest
    private lazy var urlSession: URLSession = {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        return session
    }()
    
    // State variables for parsing
    private var buffer = ""
    private var eventData = ""
    private var eventType = ""
    private var lastEventId: String?
    
    init(urlRequest: URLRequest) {
        self.urlRequest = urlRequest
    }
    
    func perform() {
        self.urlSession
            .dataTask(with: self.urlRequest)
            .resume()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete?(self, error)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let stringContent = String(data: data, encoding: .utf8) else {
            onProcessingError?(self, StreamingError.unknownContent)
            return
        }
        processJSON(from: stringContent)
    }
    
}

extension StreamingSession {
    
    func processJSON(from stringContent: String) {
        // Append the new chunk to the buffer
        buffer += stringContent
        
        // Split the buffer into lines
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        
        // If the last line is not complete, keep it in the buffer
        if !buffer.hasSuffix("\n") {
            buffer = String(lines.last ?? "")
            // Exclude the last partial line from processing
            processLines(Array(lines.dropLast()))
        } else {
            buffer = ""
            processLines(Array(lines))
        }
    }
    
    private func processLines(_ lines: [Substring]) {
        for line in lines {
            if line.isEmpty {
                // Dispatch the event
                dispatchEvent()
            } else if line.hasPrefix(":") {
                // This is a comment line
                let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
                onComment?(self, String(comment))
            } else {
                // Process the field
                let split = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let field = split[0].trimmingCharacters(in: .whitespaces)
                let value = split.count > 1 ? dropLeadingSpace(str: split[1]) : ""
                processField(field: field, value: .init(value))
            }
        }
    }
    
    private func dispatchEvent() {
        // If the event data is the completion marker, finish
        if eventData.trimmingCharacters(in: .whitespacesAndNewlines) == streamingCompletionMarker {
            onComplete?(self, nil)
            // Reset state
            eventData = ""
            eventType = ""
            lastEventId = nil
            return
        }
        
        guard !eventData.isEmpty else {
            // No data to process
            eventType = ""
            return
        }
        
        // Remove the last newline character
        if eventData.hasSuffix("\n") {
            eventData.removeLast()
        }
        
        // Decode the JSON data
        guard let jsonData = eventData.data(using: .utf8) else {
            onProcessingError?(self, StreamingError.unknownContent)
            return
        }
        
        let decoder = JSONDecoder()
        do {
            let object = try decoder.decode(ResultType.self, from: jsonData)
            onReceiveContent?(self, object)
        } catch {
            // Attempt to decode an APIErrorResponse if available
            if let apiError = try? decoder.decode(APIErrorResponse.self, from: jsonData) {
                onProcessingError?(self, StreamingError.apiError(apiError))
            } else {
                onProcessingError?(self, error)
            }
        }
        
        // Reset event state
        eventData = ""
        eventType = ""
    }
    
    private func dropLeadingSpace(str: Substring) -> Substring {
        if str.first == " " {
            return str[str.index(after: str.startIndex)...]
        }
        return str
    }
    
    private func processField(field: String, value: String) {
        switch field {
        case "data":
            eventData += value + "\n" // Accumulate data with newline
        case "event":
            eventType = value
        case "id":
            lastEventId = value
        case "retry":
            // Handle retry if necessary
            if let reconnectionTime = TimeInterval(value) {
                // Update retry interval or handle accordingly
                // This example doesn't store the retry interval
            }
        default:
            break
        }
    }
    
}
