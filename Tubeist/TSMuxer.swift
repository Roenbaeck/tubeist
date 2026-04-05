//
//  TSMuxer.swift
//  Tubeist
//
//  Created by Lars Rönnbäck on 2025-10-05.
//

import Foundation
import CoreMedia

// MPEG-TS constants
private let TS_PACKET_SIZE = 188
private let TS_SYNC_BYTE: UInt8 = 0x47
private let TS_PAT_PID: UInt16 = 0x0000
private let TS_PMT_PID: UInt16 = 0x1000
private let TS_VIDEO_PID: UInt16 = 0x0100
private let TS_AUDIO_PID: UInt16 = 0x0101
private let TS_PCR_PID: UInt16 = TS_VIDEO_PID

// Stream types
private let STREAM_TYPE_HEVC: UInt8 = 0x24
private let STREAM_TYPE_AAC: UInt8 = 0x0F

// PES stream IDs
private let PES_VIDEO_STREAM_ID: UInt8 = 0xE0
private let PES_AUDIO_STREAM_ID: UInt8 = 0xC0

/// Converts HEVC length-prefixed NALUs (HVCC/hvcC format) to Annex B start code format.
/// - Parameter data: HEVC bitstream with 4-byte length prefixes
/// - Returns: HEVC bitstream with 00 00 00 01 start codes
func hevcToAnnexB(_ data: Data) -> Data {
    var result = Data()
    var offset = 0
    while offset + 4 <= data.count {
        let naluLength = Int(data[offset]) << 24 |
                         Int(data[offset + 1]) << 16 |
                         Int(data[offset + 2]) << 8 |
                         Int(data[offset + 3])
        offset += 4
        guard naluLength > 0, offset + naluLength <= data.count else { break }
        // Annex B start code
        result.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        result.append(data[offset..<offset + naluLength])
        offset += naluLength
    }
    return result
}

/// Creates an ADTS header for an AAC frame.
/// - Parameters:
///   - frameLength: Length of the raw AAC frame (without header)
///   - sampleRate: Audio sample rate in Hz
///   - channels: Number of audio channels
/// - Returns: 7-byte ADTS header
func adtsHeader(frameLength: Int, sampleRate: Double, channels: Int) -> Data {
    let profile: UInt8 = 1 // AAC-LC (profile - 1 in ADTS, so LC = 2 - 1 = 1)
    
    let freqIndex: UInt8 = {
        switch Int(sampleRate) {
        case 96000: return 0
        case 88200: return 1
        case 64000: return 2
        case 48000: return 3
        case 44100: return 4
        case 32000: return 5
        case 24000: return 6
        case 22050: return 7
        case 16000: return 8
        case 12000: return 9
        case 11025: return 10
        case 8000:  return 11
        default:    return 4  // default to 44100
        }
    }()
    
    let channelConf = UInt8(min(channels, 7))
    let fullLength = frameLength + 7  // ADTS header is 7 bytes
    
    var header = Data(count: 7)
    // Syncword 0xFFF, ID=0 (MPEG-4), Layer=00, Protection absent=1
    header[0] = 0xFF
    header[1] = 0xF1
    // Profile(2) | SamplingFreqIndex(4) | PrivateBit(1) | ChannelConfig high bit(1)
    header[2] = (profile << 6) | (freqIndex << 2) | (0 << 1) | (channelConf >> 2)
    // ChannelConfig low 2 bits(2) | OrigCopy(1) | Home(1) | CopyrightIDBit(1) | CopyrightIDStart(1) | FrameLength high 2 bits(2)
    header[3] = ((channelConf & 0x03) << 6) | UInt8((fullLength >> 11) & 0x03)
    // FrameLength middle 8 bits
    header[4] = UInt8((fullLength >> 3) & 0xFF)
    // FrameLength low 3 bits(3) | Buffer fullness high 5 bits (0x7FF = VBR)
    header[5] = UInt8((fullLength & 0x07) << 5) | 0x1F
    // Buffer fullness low 6 bits | Number of AAC frames - 1 (0)
    header[6] = 0xFC
    return header
}

/// MPEG-TS muxer that produces Transport Stream segments from encoded HEVC and AAC data.
struct TSMuxer {
    private var videoContinuityCounter: UInt8 = 0
    private var audioContinuityCounter: UInt8 = 0
    private var patContinuityCounter: UInt8 = 0
    private var pmtContinuityCounter: UInt8 = 0
    
    /// Generates PAT (Program Association Table) packets.
    mutating func generatePAT() -> Data {
        // PAT table payload
        var tablePayload = Data()
        // table_id = 0x00
        tablePayload.append(0x00)
        // section_syntax_indicator(1) | 0(1) | reserved(2) | section_length(12)
        // section_length = tsid(2) + version(1) + section_num(1) + last_section_num(1)
        //                + program_entry(4) + CRC(4) = 13
        let sectionLength: UInt16 = 13
        tablePayload.append(UInt8(0x80 | 0x30 | ((sectionLength >> 8) & 0x0F)))
        tablePayload.append(UInt8(sectionLength & 0xFF))
        // transport_stream_id = 1
        tablePayload.append(0x00)
        tablePayload.append(0x01)
        // reserved(2) | version(5) | current_next(1)
        tablePayload.append(0xC1)
        // section_number
        tablePayload.append(0x00)
        // last_section_number
        tablePayload.append(0x00)
        // program_number = 1
        tablePayload.append(0x00)
        tablePayload.append(0x01)
        // reserved(3) | PMT PID(13)
        tablePayload.append(UInt8(0xE0 | ((TS_PMT_PID >> 8) & 0x1F)))
        tablePayload.append(UInt8(TS_PMT_PID & 0xFF))
        
        // CRC32
        let crc = crc32mpeg2(tablePayload)
        tablePayload.append(UInt8((crc >> 24) & 0xFF))
        tablePayload.append(UInt8((crc >> 16) & 0xFF))
        tablePayload.append(UInt8((crc >> 8) & 0xFF))
        tablePayload.append(UInt8(crc & 0xFF))
        
        return wrapInTSPacket(payload: tablePayload, pid: TS_PAT_PID,
                              continuityCounter: &patContinuityCounter,
                              payloadUnitStart: true, withPointerField: true)
    }
    
    /// Generates PMT (Program Map Table) packets for HEVC + AAC.
    mutating func generatePMT() -> Data {
        var tablePayload = Data()
        // table_id = 0x02
        tablePayload.append(0x02)
        // section_length: bytes after this field through CRC
        // 5 (program_number + version + section nums) + 4 (PCR + prog info len) + 5*2 (streams) + 4 (CRC) = 23
        let sectionLength: UInt16 = 23
        tablePayload.append(UInt8(0x80 | 0x30 | ((sectionLength >> 8) & 0x0F)))
        tablePayload.append(UInt8(sectionLength & 0xFF))
        // program_number = 1
        tablePayload.append(0x00)
        tablePayload.append(0x01)
        // reserved(2) | version(5) | current_next(1)
        tablePayload.append(0xC1)
        // section_number
        tablePayload.append(0x00)
        // last_section_number
        tablePayload.append(0x00)
        // reserved(3) | PCR_PID(13)
        tablePayload.append(UInt8(0xE0 | ((TS_PCR_PID >> 8) & 0x1F)))
        tablePayload.append(UInt8(TS_PCR_PID & 0xFF))
        // reserved(4) | program_info_length(12) = 0
        tablePayload.append(0xF0)
        tablePayload.append(0x00)
        
        // Video stream entry: HEVC
        tablePayload.append(STREAM_TYPE_HEVC)
        tablePayload.append(UInt8(0xE0 | ((TS_VIDEO_PID >> 8) & 0x1F)))
        tablePayload.append(UInt8(TS_VIDEO_PID & 0xFF))
        // ES_info_length = 0
        tablePayload.append(0xF0)
        tablePayload.append(0x00)
        
        // Audio stream entry: AAC
        tablePayload.append(STREAM_TYPE_AAC)
        tablePayload.append(UInt8(0xE0 | ((TS_AUDIO_PID >> 8) & 0x1F)))
        tablePayload.append(UInt8(TS_AUDIO_PID & 0xFF))
        // ES_info_length = 0
        tablePayload.append(0xF0)
        tablePayload.append(0x00)
        
        // CRC32
        let crc = crc32mpeg2(tablePayload)
        tablePayload.append(UInt8((crc >> 24) & 0xFF))
        tablePayload.append(UInt8((crc >> 16) & 0xFF))
        tablePayload.append(UInt8((crc >> 8) & 0xFF))
        tablePayload.append(UInt8(crc & 0xFF))
        
        return wrapInTSPacket(payload: tablePayload, pid: TS_PMT_PID,
                              continuityCounter: &pmtContinuityCounter,
                              payloadUnitStart: true, withPointerField: true)
    }
    
    /// Muxes an encoded video access unit into TS packets with PES wrapping.
    /// - Parameters:
    ///   - data: Annex B encoded HEVC data
    ///   - pts: Presentation timestamp in 90kHz ticks
    ///   - dts: Decode timestamp in 90kHz ticks (may equal pts if no B-frames)
    ///   - isKeyFrame: Whether this is an IDR/random access point
    /// - Returns: Concatenated TS packets
    mutating func muxVideo(data: Data, pts: Int64, dts: Int64, isKeyFrame: Bool) -> Data {
        let pesPacket = buildPES(streamID: PES_VIDEO_STREAM_ID, data: data, pts: pts, dts: dts)
        return splitIntoPESPackets(pesPayload: pesPacket, pid: TS_VIDEO_PID,
                                   continuityCounter: &videoContinuityCounter,
                                   isKeyFrame: isKeyFrame, pcrValue: dts)
    }
    
    /// Muxes an AAC audio frame (with ADTS header) into TS packets with PES wrapping.
    /// - Parameters:
    ///   - data: AAC data with ADTS header
    ///   - pts: Presentation timestamp in 90kHz ticks
    /// - Returns: Concatenated TS packets
    mutating func muxAudio(data: Data, pts: Int64) -> Data {
        let pesPacket = buildPES(streamID: PES_AUDIO_STREAM_ID, data: data, pts: pts, dts: nil)
        return splitIntoPESPackets(pesPayload: pesPacket, pid: TS_AUDIO_PID,
                                   continuityCounter: &audioContinuityCounter,
                                   isKeyFrame: false, pcrValue: nil)
    }
    
    /// Resets all continuity counters (call when starting a new segment).
    mutating func reset() {
        videoContinuityCounter = 0
        audioContinuityCounter = 0
        patContinuityCounter = 0
        pmtContinuityCounter = 0
    }
    
    // MARK: - Private helpers
    
    /// Builds a PES (Packetized Elementary Stream) packet.
    private func buildPES(streamID: UInt8, data: Data, pts: Int64, dts: Int64?) -> Data {
        let hasDTS = dts != nil && dts != pts
        let headerDataLength: UInt8 = hasDTS ? 10 : 5
        let flags: UInt8 = hasDTS ? 0xC0 : 0x80  // PTS+DTS or PTS only
        
        // PES packet length: 3 (flags + header length) + headerDataLength + data
        // For video, set to 0 (unbounded) since frames can exceed 65535
        let pesPacketLength: UInt16 = (streamID & 0xF0) == 0xE0 ? 0 :
            UInt16(min(Int(3) + Int(headerDataLength) + data.count, 65535))
        
        var pes = Data()
        // Start code prefix: 00 00 01
        pes.append(contentsOf: [0x00, 0x00, 0x01])
        // Stream ID
        pes.append(streamID)
        // PES packet length
        pes.append(UInt8(pesPacketLength >> 8))
        pes.append(UInt8(pesPacketLength & 0xFF))
        // Flags byte 1: marker(2)=10 | scrambling(2)=00 | priority(1)=0 | alignment(1)=1 | copyright(1)=0 | original(1)=0
        pes.append(0x84)
        // Flags byte 2: PTS/DTS flags
        pes.append(flags)
        // PES header data length
        pes.append(headerDataLength)
        
        // PTS (5 bytes)
        pes.append(contentsOf: encodePTS(pts, marker: hasDTS ? 0x03 : 0x02))
        
        // DTS (5 bytes, if present)
        if hasDTS, let dtsValue = dts {
            pes.append(contentsOf: encodePTS(dtsValue, marker: 0x01))
        }
        
        // ES data
        pes.append(data)
        
        return pes
    }
    
    /// Encodes a timestamp into the 5-byte PES timestamp format.
    private func encodePTS(_ timestamp: Int64, marker: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 5)
        bytes[0] = (marker << 4) | (UInt8((timestamp >> 29) & 0x0E)) | 0x01
        bytes[1] = UInt8((timestamp >> 22) & 0xFF)
        bytes[2] = UInt8(((timestamp >> 14) & 0xFE)) | 0x01
        bytes[3] = UInt8((timestamp >> 7) & 0xFF)
        bytes[4] = UInt8((timestamp << 1) & 0xFE) | 0x01
        return bytes
    }
    
    /// Splits a PES packet into 188-byte TS packets.
    private func splitIntoPESPackets(pesPayload: Data, pid: UInt16,
                                     continuityCounter: inout UInt8,
                                     isKeyFrame: Bool, pcrValue: Int64?) -> Data {
        var result = Data()
        var offset = 0
        var isFirst = true
        
        while offset < pesPayload.count {
            var packet = Data(repeating: 0xFF, count: TS_PACKET_SIZE)
            
            // Sync byte
            packet[0] = TS_SYNC_BYTE
            
            // PID + payload unit start
            let payloadUnitStart: UInt8 = isFirst ? 0x40 : 0x00
            packet[1] = payloadUnitStart | UInt8((pid >> 8) & 0x1F)
            packet[2] = UInt8(pid & 0xFF)
            
            let remaining = pesPayload.count - offset
            
            // First packet of a keyframe video PES: include adaptation field with PCR + RAI
            if isFirst && (isKeyFrame || pcrValue != nil) {
                // adaptation_field_control = 0x30 (both)
                packet[3] = 0x30 | (continuityCounter & 0x0F)
                
                let flags: UInt8 = (pcrValue != nil ? 0x10 : 0x00) | (isKeyFrame ? 0x40 : 0x00)
                
                if let pcr = pcrValue {
                    // Adaptation: 1 flags + 6 PCR = 7 bytes content, adaptation_field_length = 7
                    let adaptContentLen = 7
                    let headerSize = 4 + 1 + adaptContentLen  // 12
                    let payloadSpace = TS_PACKET_SIZE - headerSize
                    let toCopy = min(remaining, payloadSpace)
                    let stuffNeeded = payloadSpace - toCopy
                    
                    // adaptation_field_length includes stuffing
                    packet[4] = UInt8(adaptContentLen + stuffNeeded)
                    packet[5] = flags
                    
                    // PCR (6 bytes): 33-bit base + 6 reserved + 9-bit extension
                    let pcrBase = pcr
                    packet[6] = UInt8((pcrBase >> 25) & 0xFF)
                    packet[7] = UInt8((pcrBase >> 17) & 0xFF)
                    packet[8] = UInt8((pcrBase >> 9) & 0xFF)
                    packet[9] = UInt8((pcrBase >> 1) & 0xFF)
                    packet[10] = UInt8(((pcrBase & 0x01) << 7) | 0x7E)
                    packet[11] = 0x00
                    
                    // Stuffing bytes (already 0xFF from init)
                    // Payload starts after adaptation
                    let payloadStart = TS_PACKET_SIZE - toCopy
                    if toCopy > 0 {
                        packet.replaceSubrange(payloadStart..<payloadStart + toCopy,
                                               with: pesPayload[offset..<offset + toCopy])
                    }
                    offset += toCopy
                } else {
                    // Adaptation with just flags, no PCR
                    let adaptContentLen = 1
                    let headerSize = 4 + 1 + adaptContentLen  // 6
                    let payloadSpace = TS_PACKET_SIZE - headerSize
                    let toCopy = min(remaining, payloadSpace)
                    let stuffNeeded = payloadSpace - toCopy
                    
                    packet[4] = UInt8(adaptContentLen + stuffNeeded)
                    packet[5] = flags
                    
                    let payloadStart = TS_PACKET_SIZE - toCopy
                    if toCopy > 0 {
                        packet.replaceSubrange(payloadStart..<payloadStart + toCopy,
                                               with: pesPayload[offset..<offset + toCopy])
                    }
                    offset += toCopy
                }
            } else {
                let payloadSpace = TS_PACKET_SIZE - 4
                let toCopy = min(remaining, payloadSpace)
                
                if toCopy == payloadSpace {
                    // Full payload, no adaptation field needed
                    packet[3] = 0x10 | (continuityCounter & 0x0F)
                    packet.replaceSubrange(4..<4 + toCopy,
                                           with: pesPayload[offset..<offset + toCopy])
                } else {
                    // Need stuffing via adaptation field
                    packet[3] = 0x30 | (continuityCounter & 0x0F)
                    let stuffNeeded = payloadSpace - toCopy
                    
                    if stuffNeeded == 1 {
                        // Special case: adaptation_field_length = 0 (just the length byte itself)
                        packet[4] = 0x00
                    } else {
                        // adaptation_field_length, flags byte, then stuffing
                        packet[4] = UInt8(stuffNeeded - 1)
                        packet[5] = 0x00  // no flags
                        // Rest is already 0xFF from init
                    }
                    
                    let payloadStart = TS_PACKET_SIZE - toCopy
                    if toCopy > 0 {
                        packet.replaceSubrange(payloadStart..<payloadStart + toCopy,
                                               with: pesPayload[offset..<offset + toCopy])
                    }
                }
                offset += toCopy
            }
            
            continuityCounter = (continuityCounter + 1) & 0x0F
            isFirst = false
            result.append(packet)
        }
        
        return result
    }
    
    /// Wraps a PSI table (PAT/PMT) into a single TS packet with pointer field.
    private func wrapInTSPacket(payload: Data, pid: UInt16,
                                continuityCounter: inout UInt8,
                                payloadUnitStart: Bool, withPointerField: Bool) -> Data {
        var packet = Data(count: TS_PACKET_SIZE)
        
        packet[0] = TS_SYNC_BYTE
        let startBit: UInt8 = payloadUnitStart ? 0x40 : 0x00
        packet[1] = startBit | UInt8((pid >> 8) & 0x1F)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10 | (continuityCounter & 0x0F)  // payload only
        
        var offset = 4
        if withPointerField {
            packet[offset] = 0x00  // pointer_field
            offset += 1
        }
        
        let toCopy = min(payload.count, TS_PACKET_SIZE - offset)
        packet.replaceSubrange(offset..<offset + toCopy, with: payload[0..<toCopy])
        
        // Fill remainder with 0xFF stuffing
        for i in (offset + toCopy)..<TS_PACKET_SIZE {
            packet[i] = 0xFF
        }
        
        continuityCounter = (continuityCounter + 1) & 0x0F
        return packet
    }
}

/// CRC-32/MPEG-2 calculation for PAT/PMT tables.
private func crc32mpeg2(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 {
            if crc & 0x80000000 != 0 {
                crc = (crc << 1) ^ 0x04C11DB7
            } else {
                crc = crc << 1
            }
        }
    }
    return crc
}
