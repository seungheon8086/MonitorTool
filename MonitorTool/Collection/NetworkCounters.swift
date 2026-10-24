import Darwin
import Foundation
import SystemConfiguration

/// 인터페이스 하나의 누적 바이트 카운터예요. 부팅 뒤(또는 인터페이스가 생긴 뒤)부터 센 값이에요.
nonisolated struct InterfaceCounter: Hashable, Sendable {
    /// BSD 이름 (예: en0)
    var name: String
    /// 받은 바이트
    var received: UInt64
    /// 보낸 바이트
    var sent: UInt64
    /// 켜져 있고 동작 중인지 (IFF_UP과 IFF_RUNNING)
    var isActive: Bool
}

/// 인터페이스 카운터를 시스템에서 읽어요.
nonisolated enum InterfaceCounterReader {
    /// <sys/socket.h>의 NET_RT_IFLIST2: 인터페이스 목록을 64비트 카운터와 함께 받는 sysctl 이름
    private static let interfaceListWith64BitCounters: Int32 = 6
    /// <net/route.h>의 RTM_IFINFO2: 64비트 카운터(if_data64)가 든 인터페이스 정보 메시지
    private static let interfaceInfo2Message: UInt8 = 0x12

    /// 모든 인터페이스의 64비트 카운터를 읽어요. 읽지 못하면 nil이에요.
    /// (getifaddrs가 주는 카운터는 32비트라 4 GB마다 0으로 돌아가서 쓰지 않아요.)
    static func read() -> [String: InterfaceCounter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, interfaceListWith64BitCounters, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }
        // 두 번 부르는 사이에 인터페이스가 늘 수 있어서 조금 넉넉히 잡아요.
        length += 4096
        var buffer = [UInt8](repeating: 0, count: length)
        let status = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, UInt32(mib.count), bytes.baseAddress, &length, nil, 0)
        }
        guard status == 0 else {
            return nil
        }

        var counters: [String: InterfaceCounter] = [:]
        buffer.withUnsafeBytes { bytes in
            let headerSize = MemoryLayout<if_msghdr>.size
            var offset = 0
            // 메시지가 여러 개 이어져 있어요. 메시지마다 앞에 자기 길이가 적혀 있어요.
            while offset + headerSize <= length {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else {
                    break
                }
                if header.ifm_type == interfaceInfo2Message, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = interfaceName(in: bytes, messageStart: offset, messageLength: messageLength,
                                                index: message.ifm_index) {
                        let flags = message.ifm_flags
                        counters[name] = InterfaceCounter(name: name,
                                                          received: message.ifm_data.ifi_ibytes,
                                                          sent: message.ifm_data.ifi_obytes,
                                                          isActive: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0)
                    }
                }
                offset += messageLength
            }
        }
        return counters
    }

    /// 메시지 바로 뒤에 붙은 링크 주소(sockaddr_dl)에서 이름을 꺼내요. 못 꺼내면 번호로 이름을 물어봐요.
    private static func interfaceName(in bytes: UnsafeRawBufferPointer, messageStart: Int,
                                      messageLength: Int, index: UInt16) -> String? {
        let addressStart = messageStart + MemoryLayout<if_msghdr2>.size
        let messageEnd = messageStart + messageLength
        if let nameLengthOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_nlen),
           let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data),
           addressStart + nameOffset <= messageEnd {
            let nameLength = Int(bytes[addressStart + nameLengthOffset])
            let nameStart = addressStart + nameOffset
            if nameLength > 0, nameStart + nameLength <= messageEnd {
                let nameBytes = UnsafeRawBufferPointer(rebasing: bytes[nameStart..<(nameStart + nameLength)])
                let name = String(decoding: nameBytes, as: UTF8.self)
                if !name.isEmpty {
                    return name
                }
            }
        }
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(UInt32(index), &nameBuffer) != nil else {
            return nil
        }
        let nameBytes = nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return nameBytes.isEmpty ? nil : String(decoding: nameBytes, as: UTF8.self)
    }
}

/// 시스템 설정의 네트워크 화면에 나오는 인터페이스 이름이에요. (예: en0 → Wi-Fi)
nonisolated enum InterfaceDisplayNames {
    /// BSD 이름 → 보여줄 이름. 못 읽으면 빈 목록이에요.
    static func read() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else {
                continue
            }
            names[bsdName] = displayName
        }
        return names
    }
}
