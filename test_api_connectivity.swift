#!/usr/bin/env swift

//
// test_api_connectivity.swift
// Test API connectivity and response handling
//

import Foundation

// MARK: - API Connectivity Test

class APIConnectivityTester {
    private let baseURL = "https://api.myunsaidapp.com"
    private let apiKey = "37da2c87b923d4e9dd388f13580d75396c84d8ab5f9c58b505a80e892b3d7e9d"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        return URLSession(configuration: config)
    }()

    func testBasicConnectivity() async {
        print("🌐 Testing Basic API Connectivity")
        print("=================================")

        guard let url = URL(string: "\(baseURL)/health") else {
            print("❌ Invalid URL: \(baseURL)/health")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                print("📡 HTTP Status: \(httpResponse.statusCode)")

                switch httpResponse.statusCode {
                case 200..<300:
                    print("✅ API is reachable and responding")
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("📄 Response: \(responseString.prefix(200))")
                    }
                case 401:
                    print("🔐 Authentication failed - check API key")
                case 402:
                    print("💰 Payment required - trial expired")
                case 403:
                    print("🚫 Forbidden - check permissions")
                case 404:
                    print("🔍 Endpoint not found")
                case 500..<600:
                    print("💥 Server error")
                default:
                    print("❓ Unexpected status code")
                }
            } else {
                print("❌ No HTTP response received")
            }
        } catch {
            print("❌ Network error: \(error.localizedDescription)")
        }

        print()
    }

    func testToneAnalysisEndpoint() async {
        print("🎯 Testing Tone Analysis Endpoint")
        print("================================")

        guard let url = URL(string: "\(baseURL)/api/v1/tone") else {
            print("❌ Invalid URL: \(baseURL)/api/v1/tone")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "text": "I really appreciate your help with this project",
            "context": "general",
            "userId": "test_user_123",
            "client_seq": 1
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                print("📡 HTTP Status: \(httpResponse.statusCode)")

                switch httpResponse.statusCode {
                case 200..<300:
                    print("✅ Tone analysis endpoint working")
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("📄 Response: \(responseString)")
                    }

                    // Parse the response
                    if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        if let uiTone = json["ui_tone"] as? String {
                            print("🎨 UI Tone: \(uiTone)")
                        }
                        if let clientSeq = json["client_seq"] as? Int {
                            print("🔢 Client Seq: \(clientSeq)")
                        }
                    }

                case 401:
                    print("🔐 Authentication failed - API key invalid")
                case 402:
                    print("💰 Payment required - trial expired or subscription needed")
                case 403:
                    print("🚫 Forbidden - check API permissions")
                case 404:
                    print("🔍 Tone analysis endpoint not found")
                case 429:
                    print("⏱️ Rate limited - too many requests")
                case 500..<600:
                    print("💥 Server error")
                default:
                    print("❓ Unexpected status code: \(httpResponse.statusCode)")
                }
            } else {
                print("❌ No HTTP response received")
            }
        } catch {
            print("❌ Network error: \(error.localizedDescription)")
        }

        print()
    }

    func testDifferentTextSamples() async {
        print("📝 Testing Different Text Samples")
        print("=================================")

        let testTexts = [
            "I really appreciate your help",
            "This is frustrating and annoying",
            "You did a great job on this",
            "I hate waiting for responses",
            "Thank you for your assistance"
        ]

        for text in testTexts {
            print("Testing: \"\(text)\"")

            guard let url = URL(string: "\(baseURL)/api/v1/tone") else {
                print("❌ Invalid URL")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let payload: [String: Any] = [
                "text": text,
                "context": "general",
                "userId": "test_user_123",
                "client_seq": Int.random(in: 1...1000)
            ]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                           let uiTone = json["ui_tone"] as? String {
                            print("  ✅ Tone: \(uiTone)")
                        } else {
                            print("  ⚠️ Could not parse response")
                        }
                    } else if httpResponse.statusCode == 402 {
                        print("  💰 Trial expired for this text")
                        break // Stop testing if trial expired
                    } else {
                        print("  ❌ Status: \(httpResponse.statusCode)")
                    }
                }
            } catch {
                print("  ❌ Error: \(error.localizedDescription)")
            }

            // Small delay between requests
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        print()
    }
}

// MARK: - Main Test Runner

func runConnectivityTests() async {
    print("🚀 API Connectivity Test Suite")
    print("==============================")
    print()

    let tester = APIConnectivityTester()

    await tester.testBasicConnectivity()
    await tester.testToneAnalysisEndpoint()
    await tester.testDifferentTextSamples()

    print("✅ Connectivity tests completed!")
    print()
    print("📋 Summary:")
    print("- Check HTTP status codes for trial/subscription issues")
    print("- 402 = Trial expired, subscription required")
    print("- 401 = API key invalid")
    print("- 200 = Success")
    print("- Network errors indicate connectivity issues")
}

Task {
    await runConnectivityTests()
}