#!/usr/bin/env swift

//
// test_api_connectivity_sync.swift
// Synchronous test for API connectivity
//

import Foundation

// MARK: - Synchronous API Test

func testAPIConnectivity() {
    print("🌐 Testing API Connectivity")
    print("==========================")

    let baseURL = "https://api.myunsaidapp.com"
    let apiKey = "37da2c87b923d4e9dd388f13580d75396c84d8ab5f9c58b505a80e892b3d7e9d"

    // Test basic health endpoint
    testEndpoint("\(baseURL)/health", method: "GET", apiKey: apiKey, description: "Health Check")

    // Test tone analysis endpoint
    testToneAnalysis(baseURL, apiKey: apiKey)
}

func testEndpoint(_ urlString: String, method: String, apiKey: String, description: String) {
    print("\n📡 Testing: \(description)")
    print("URL: \(urlString)")

    guard let url = URL(string: urlString) else {
        print("❌ Invalid URL")
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10.0

    let semaphore = DispatchSemaphore(value: 0)
    var result: (success: Bool, statusCode: Int?, error: String?) = (false, nil, nil)

    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            result = (false, nil, error.localizedDescription)
        } else if let httpResponse = response as? HTTPURLResponse {
            result = (true, httpResponse.statusCode, nil)

            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                print("📄 Response: \(responseString.prefix(200))")
            }
        }
        semaphore.signal()
    }.resume()

    semaphore.wait()

    if let statusCode = result.statusCode {
        print("📊 Status: \(statusCode)")
        switch statusCode {
        case 200..<300:
            print("✅ Success")
        case 401:
            print("🔐 Authentication failed")
        case 402:
            print("💰 Trial expired - subscription required")
        case 403:
            print("🚫 Forbidden")
        case 404:
            print("🔍 Not found")
        case 500..<600:
            print("💥 Server error")
        default:
            print("❓ Unexpected status")
        }
    } else if let error = result.error {
        print("❌ Error: \(error)")
    }
}

func testToneAnalysis(_ baseURL: String, apiKey: String) {
    print("\n🎯 Testing Tone Analysis")
    print("URL: \(baseURL)/api/v1/tone")

    guard let url = URL(string: "\(baseURL)/api/v1/tone") else {
        print("❌ Invalid URL")
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15.0

    let payload: [String: Any] = [
        "text": "I really appreciate your help with this",
        "context": "general",
        "userId": "test_user_123",
        "client_seq": 1
    ]

    do {
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let semaphore = DispatchSemaphore(value: 0)
        var result: (success: Bool, statusCode: Int?, response: String?, error: String?) = (false, nil, nil, nil)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                result = (false, nil, nil, error.localizedDescription)
            } else if let httpResponse = response as? HTTPURLResponse {
                let responseString = data.flatMap { String(data: $0, encoding: .utf8) }
                result = (true, httpResponse.statusCode, responseString, nil)
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let statusCode = result.statusCode {
            print("📊 Status: \(statusCode)")
            switch statusCode {
            case 200..<300:
                print("✅ Tone analysis working")
                if let response = result.response {
                    print("📄 Response: \(response)")

                    // Try to parse JSON
                    if let data = response.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        if let uiTone = json["ui_tone"] as? String {
                            print("🎨 UI Tone: \(uiTone)")
                        }
                        if let clientSeq = json["client_seq"] as? Int {
                            print("🔢 Client Seq: \(clientSeq)")
                        }
                    }
                }
            case 401:
                print("🔐 Authentication failed - API key may be invalid")
            case 402:
                print("💰 Trial expired - subscription required")
                print("🎯 This is likely blocking the tone indicator!")
            case 403:
                print("🚫 Forbidden - check API permissions")
            case 404:
                print("🔍 Tone analysis endpoint not found")
            case 429:
                print("⏱️ Rate limited")
            case 500..<600:
                print("💥 Server error")
            default:
                print("❓ Unexpected status: \(statusCode)")
            }
        } else if let error = result.error {
            print("❌ Network Error: \(error)")
        }

    } catch {
        print("❌ JSON Error: \(error.localizedDescription)")
    }
}

// MARK: - Main

testAPIConnectivity()

print("\n✅ API connectivity test completed!")
print("\n🔍 Key indicators:")
print("- 402 status = Trial expired (subscription needed)")
print("- 401 status = API key invalid")
print("- 200 status = API working correctly")
print("- Network errors = Connectivity issues")