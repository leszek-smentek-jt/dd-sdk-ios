/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

class URLSessionTracingHandlerTests: XCTestCase {
    private let spanOutput = SpanOutputMock()
    private let logOutput = LogOutputMock()
    private let handler = URLSessionTracingHandler()

    override func setUp() {
        Global.sharedTracer = Tracer.mockWith(
            spanOutput: spanOutput,
            logOutput: .init(
                logBuilder: .mockAny(),
                loggingOutput: logOutput
            )
        )
        super.setUp()
    }

    override func tearDown() {
        Global.sharedTracer = DDNoopGlobals.tracer
        super.tearDown()
    }

    func testGivenFirstPartyInterceptionWithSpanContext_whenInterceptionCompletes_itUsesInjectedSpanContext() throws {
        let spanSentExpectation = expectation(description: "Send span")
        spanOutput.onSpanRecorded = { _ in spanSentExpectation.fulfill() }

        // Given
        let interception = TaskInterception(request: .mockAny(), isFirstParty: true)
        interception.register(completion: .mockAny())
        interception.register(
            metrics: .mockWith(
                fetch: .init(
                    start: .mockDecember15th2019At10AMUTC(),
                    end: .mockDecember15th2019At10AMUTC(addingTimeInterval: 1)
                )
            )
        )
        interception.register(
            spanContext: .mockWith(traceID: 100, spanID: 200, parentSpanID: nil)
        )

        // When
        handler.notify_taskInterceptionCompleted(interception: interception)

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let span = try XCTUnwrap(spanOutput.recordedSpan)
        XCTAssertEqual(span.traceID.rawValue, 100)
        XCTAssertEqual(span.spanID.rawValue, 200)
        XCTAssertEqual(span.operationName, "urlsession.request")
        XCTAssertFalse(span.isError)
        XCTAssertEqual(span.duration, 1)

        let log = logOutput.recordedLog
        XCTAssertNil(log)
    }

    func testGivenFirstPartyInterceptionWithNoError_whenInterceptionCompletes_itEncodesRequestInfoInSpan() throws {
        let spanSentExpectation = expectation(description: "Send span")
        spanOutput.onSpanRecorded = { _ in spanSentExpectation.fulfill() }

        // Given
        let request: URLRequest = .mockWith(httpMethod: "POST")
        let interception = TaskInterception(request: request, isFirstParty: true)
        interception.register(completion: .mockWith(response: .mockResponseWith(statusCode: 200), error: nil))
        interception.register(
            metrics: .mockWith(
                fetch: .init(
                    start: .mockDecember15th2019At10AMUTC(),
                    end: .mockDecember15th2019At10AMUTC(addingTimeInterval: 2)
                )
            )
        )

        // When
        handler.notify_taskInterceptionCompleted(interception: interception)

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let span = try XCTUnwrap(spanOutput.recordedSpan)
        XCTAssertEqual(span.operationName, "urlsession.request")
        XCTAssertFalse(span.isError)
        XCTAssertEqual(span.duration, 2)
        XCTAssertEqual(span.resource, request.url!.absoluteString)
        XCTAssertEqual(span.tags[OTTags.httpUrl]?.encodable.value as? String, request.url!.absoluteString)
        XCTAssertEqual(span.tags[OTTags.httpMethod]?.encodable.value as? String, "POST")
        XCTAssertEqual(span.tags[OTTags.httpStatusCode]?.encodable.value as? Int, 200)
        XCTAssertEqual(span.tags.count, 3)

        let log = logOutput.recordedLog
        XCTAssertNil(log)
    }

    func testGivenFirstPartyInterceptionWithNetworkError_whenInterceptionCompletes_itEncodesRequestInfoInSpanAndSendsLog() throws {
        let spanSentExpectation = expectation(description: "Send span")
        spanOutput.onSpanRecorded = { _ in spanSentExpectation.fulfill() }

        // Given
        let request: URLRequest = .mockWith(httpMethod: "GET")
        let error = NSError(domain: "domain", code: 123, userInfo: [NSLocalizedDescriptionKey: "network error"])
        let interception = TaskInterception(request: request, isFirstParty: true)
        interception.register(completion: .mockWith(response: nil, error: error))
        interception.register(
            metrics: .mockWith(
                fetch: .init(
                    start: .mockDecember15th2019At10AMUTC(),
                    end: .mockDecember15th2019At10AMUTC(addingTimeInterval: 30)
                )
            )
        )

        // When
        handler.notify_taskInterceptionCompleted(interception: interception)

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let span = try XCTUnwrap(spanOutput.recordedSpan)
        XCTAssertEqual(span.operationName, "urlsession.request")
        XCTAssertEqual(span.resource, request.url!.absoluteString)
        XCTAssertEqual(span.duration, 30)
        XCTAssertTrue(span.isError)
        XCTAssertEqual(span.tags[OTTags.httpUrl]?.encodable.value as? String, request.url!.absoluteString)
        XCTAssertEqual(span.tags[OTTags.httpMethod]?.encodable.value as? String, "GET")
        XCTAssertEqual(span.tags[DDTags.errorType]?.encodable.value as? String, "domain - 123")
        XCTAssertEqual(
            span.tags[DDTags.errorStack]?.encodable.value as? String,
            "Error Domain=domain Code=123 \"network error\" UserInfo={NSLocalizedDescription=network error}"
        )
        XCTAssertEqual(span.tags[DDTags.errorMessage]?.encodable.value as? String, "network error")
        XCTAssertEqual(span.tags.count, 5)

        let log = try XCTUnwrap(logOutput.recordedLog, "It should send error log")
        XCTAssertEqual(log.status, .error)
        XCTAssertEqual(log.message, "network error")
        XCTAssertEqual(
            log.attributes.internalAttributes?[LoggingForTracingAdapter.TracingAttributes.traceID] as? String,
            "\(span.traceID.rawValue)"
        )
        XCTAssertEqual(
            log.attributes.internalAttributes?[LoggingForTracingAdapter.TracingAttributes.spanID] as? String,
            "\(span.spanID.rawValue)"
        )
        XCTAssertEqual(
            log.attributes.internalAttributes?[OTLogFields.errorKind] as? String,
            "domain - 123"
        )
        XCTAssertEqual(log.attributes.internalAttributes?.count, 3)
        XCTAssertEqual(
            log.attributes.userAttributes[OTLogFields.event] as? String,
            "error"
        )
        XCTAssertEqual(
            log.attributes.userAttributes[OTLogFields.stack] as? String,
            "Error Domain=domain Code=123 \"network error\" UserInfo={NSLocalizedDescription=network error}"
        )
        XCTAssertEqual(log.attributes.userAttributes.count, 2)
    }

    func testGivenFirstPartyInterceptionWithClientError_whenInterceptionCompletes_itEncodesRequestInfoInSpanAndSendsLog() throws {
        let spanSentExpectation = expectation(description: "Send span")
        spanOutput.onSpanRecorded = { _ in spanSentExpectation.fulfill() }

        // Given
        let request: URLRequest = .mockWith(httpMethod: "GET")
        let interception = TaskInterception(request: request, isFirstParty: true)
        interception.register(completion: .mockWith(response: .mockResponseWith(statusCode: 404), error: nil))
        interception.register(
            metrics: .mockWith(
                fetch: .init(
                    start: .mockDecember15th2019At10AMUTC(),
                    end: .mockDecember15th2019At10AMUTC(addingTimeInterval: 2)
                )
            )
        )

        // When
        handler.notify_taskInterceptionCompleted(interception: interception)

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)

        let span = try XCTUnwrap(spanOutput.recordedSpan)
        XCTAssertEqual(span.operationName, "urlsession.request")
        XCTAssertEqual(span.resource, "404")
        XCTAssertEqual(span.duration, 2)
        XCTAssertTrue(span.isError)
        XCTAssertEqual(span.tags[OTTags.httpUrl]?.encodable.value as? String, request.url!.absoluteString)
        XCTAssertEqual(span.tags[OTTags.httpMethod]?.encodable.value as? String, "GET")
        XCTAssertEqual(span.tags[OTTags.httpStatusCode]?.encodable.value as? Int, 404)
        XCTAssertEqual(span.tags[DDTags.errorType]?.encodable.value as? String, "HTTPURLResponse - 404")
        XCTAssertEqual(span.tags[DDTags.errorMessage]?.encodable.value as? String, "404 not found")
        XCTAssertEqual(
            span.tags[DDTags.errorStack]?.encodable.value as? String,
            "Error Domain=HTTPURLResponse Code=404 \"404 not found\" UserInfo={NSLocalizedDescription=404 not found}"
        )
        XCTAssertEqual(span.tags.count, 6)

        let log = try XCTUnwrap(logOutput.recordedLog, "It should send error log")
        XCTAssertEqual(log.status, .error)
        XCTAssertEqual(log.message, "404 not found")
        XCTAssertEqual(
            log.attributes.internalAttributes?[LoggingForTracingAdapter.TracingAttributes.traceID] as? String,
            "\(span.traceID.rawValue)"
        )
        XCTAssertEqual(
            log.attributes.internalAttributes?[LoggingForTracingAdapter.TracingAttributes.spanID] as? String,
            "\(span.spanID.rawValue)"
        )
        XCTAssertEqual(
            log.attributes.internalAttributes?[OTLogFields.errorKind] as? String,
            "HTTPURLResponse - 404"
        )
        XCTAssertEqual(log.attributes.internalAttributes?.count, 3)
        XCTAssertEqual(
            log.attributes.userAttributes[OTLogFields.event] as? String,
            "error"
        )
        XCTAssertEqual(
            log.attributes.userAttributes[OTLogFields.stack] as? String,
            "Error Domain=HTTPURLResponse Code=404 \"404 not found\" UserInfo={NSLocalizedDescription=404 not found}"
        )
        XCTAssertEqual(log.attributes.userAttributes.count, 2)
    }

    func testGivenFirstPartyIncompleteInterception_whenInterceptionCompletes_itDoesNotSendTheSpan() throws {
        let spanNotSentExpectation = expectation(description: "Do not send span")
        spanNotSentExpectation.isInverted = true
        spanOutput.onSpanRecorded = { _ in spanNotSentExpectation.fulfill() }

        // Given
        let incompleteInterception = TaskInterception(request: .mockAny(), isFirstParty: true)
        // `incompleteInterception` has no metrics and no completion

        // When
        handler.notify_taskInterceptionCompleted(interception: incompleteInterception)

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)
        XCTAssertNil(spanOutput.recordedSpan)
    }

    func testGivenThirdPartyInterception_whenInterceptionCompletes_itDoesNotSendTheSpan() throws {
        let spanNotSentExpectation = expectation(description: "Do not send span")
        spanNotSentExpectation.isInverted = true
        spanOutput.onSpanRecorded = { _ in spanNotSentExpectation.fulfill() }

        // Given
        let interception = TaskInterception(request: .mockAny(), isFirstParty: false)
        interception.register(completion: .mockAny())
        interception.register(
            metrics: .mockWith(
                fetch: .init(
                    start: .mockDecember15th2019At10AMUTC(),
                    end: .mockDecember15th2019At10AMUTC(addingTimeInterval: 1)
                )
            )
        )

        // When
        handler.notify_taskInterceptionCompleted(interception: interception)

        // Then
        waitForExpectations(timeout: 0.5, handler: nil)
        XCTAssertNil(spanOutput.recordedSpan)
        XCTAssertNil(logOutput.recordedLog)
    }
}
