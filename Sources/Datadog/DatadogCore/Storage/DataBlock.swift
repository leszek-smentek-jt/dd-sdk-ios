/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Block size binary type
internal typealias BlockSize = UInt32

/// Default max data lenght in block (safety check) - 10 MB
private let MAX_DATA_LENGHT: UInt64 = 10 * 1_024 * 1_024

/// Block type supported in data stream
internal enum BlockType: UInt16 {
    case event = 0x00
}

/// Reported errors while manipulating data blocks.
internal enum DataBlockError: Error {
    case readOperationFailed(streamError: Error?)
    case invalidDataType
    case invalidByteSequence
    case bytesLengthExceedsLimit(limit: UInt64)
    case dataAllocationFailure
    case endOfStream
}

/// A data block in defined by its type and a byte sequence.
///
/// A block can be serialized in data stream by following TLV format.
internal struct DataBlock {
    /// Type describing the data block.
    let type: BlockType

    /// The data.
    var data: Data

    /// Returns a Data block in Type-Lenght-Value format.
    ///
    /// A block follow TLV with bytes aligned such as:
    ///
    ///     +-  2 bytes -+-   4 bytes   -+- n bytes -|
    ///     | block type | data size (n) |    data   |
    ///     +------------+---------------+-----------+
    /// - Parameter maxLenght: Maximum data lenght of a block.
    /// - Returns: a data block in TLV.
    func serialize(maxLenght: UInt64 = MAX_DATA_LENGHT) throws -> Data {
        var buffer = Data()
        // T
        withUnsafeBytes(of: type.rawValue) { buffer.append(contentsOf: $0) }
        // L
        guard let length = BlockSize(exactly: data.count), length <= maxLenght else {
            throw DataBlockError.bytesLengthExceedsLimit(limit: maxLenght)
        }
        withUnsafeBytes(of: length) { buffer.append(contentsOf: $0) }
        // V
        buffer += data
        return buffer
    }
}

/// A block reader can read TLV formatted blocks from a data input.
///
/// This class provides methods to iteratively retrieve a sequence of
/// `DataBlock`.
internal final class DataBlockReader {
    /// The input data stream.
    private let stream: InputStream

    /// Maximum data lenght of a block.
    private let maxBlockLenght: UInt64

    /// Reads block from an input stream.
    ///
    /// At initilization, the reader will open the stream, it will be closed
    /// when the reader instance is deallocated.
    ///
    /// - Parameter stream: The input stream
    init(
        input stream: InputStream,
        maxBlockLenght: UInt64 = MAX_DATA_LENGHT
    ) {
        self.maxBlockLenght = maxBlockLenght
        self.stream = stream
        stream.open()
    }

    deinit {
        stream.close()
    }

    /// Reads the next data block started at current index in data input.
    ///
    /// This method returns `nil` when the entire data was traversed but no more
    /// block could be found.
    ///
    /// - Throws: `DataBlockError` while reading the input stream.
    /// - Returns: The next block or nil if none could be found.
    func next() throws -> DataBlock? {
        // look for the next known block
        while true {
            do {
                return try readBlock()
            } catch DataBlockError.invalidDataType {
                continue
            } catch DataBlockError.endOfStream {
                // Some streams won't return false for hasBytesAvailable until a read is attempted
                return nil
            } catch {
                throw error
            }
        }
    }

    /// Reads all data blocks from current index in the stream.
    ///
    /// - Throws: `DataBlockError` while reading the input stream.
    /// - Returns: The block sequence found in the input
    func all(maxDataLenght: UInt64 = MAX_DATA_LENGHT) throws -> [DataBlock] {
        var blocks: [DataBlock] = []

        while let block = try next() {
            blocks.append(block)
        }

        return blocks
    }

    /// Reads `length` bytes from stream.
    ///
    /// - Parameter length: The number of byte to read
    /// - Throws: `DataBlockError` while reading the input stream.
    /// - Returns: Data bytes from stream.
    private func read(length: Int) throws -> Data {
        guard length > 0 else {
            return Data()
        }

        // Load from stream directly to data without unnecessary copies
        var data = Data(count: length)
        let count: Int = try data.withUnsafeMutableBytes {
            guard let buffer = $0.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw DataBlockError.dataAllocationFailure
            }
            return stream.read(buffer, maxLength: length)
        }

        if count < 0 {
            throw DataBlockError.readOperationFailed(streamError: stream.streamError)
        }

        if count == 0 {
            throw DataBlockError.endOfStream
        }

        guard count == length else {
            throw DataBlockError.invalidByteSequence
        }

        return data
    }

    /// Reads a block.
    private func readBlock() throws -> DataBlock {
        // read an entire block before inferring the data type
        // to leave the stream in a usuable state if an unkown
        // type was encountered.
        let type = try readType()
        let data = try readData()

        guard let type = BlockType(rawValue: type) else {
            throw DataBlockError.invalidDataType
        }

        return DataBlock(type: type, data: data)
    }

    /// Reads a block type.
    private func readType() throws -> BlockType.RawValue {
        let data = try read(length: MemoryLayout<BlockType.RawValue>.size)
        return data.withUnsafeBytes { $0.load(as: BlockType.RawValue.self) }
    }

    /// Reads block data.
    private func readData() throws -> Data {
        let data = try read(length: MemoryLayout<BlockSize>.size)
        let size = data.withUnsafeBytes { $0.load(as: BlockSize.self) }

        // even if `Int` is able to represent all `BlockSize` on 64 bit
        // arch, we make sure to avoid overflow and get the exact data
        // length.
        // Additionally check that length hasn't been corrupted and
        // we don't try to generate a huge buffer.
        guard let length = Int(exactly: size), length <= maxBlockLenght else {
            throw DataBlockError.bytesLengthExceedsLimit(limit: maxBlockLenght)
        }

        return try read(length: length)
    }
}
