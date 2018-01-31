//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Special `Error` that may be thrown if we fail to create a `SocketAddress`.
public enum SocketAddressError: Error {
    /// The host is unknown (could not be resolved).
    case unknown(host: String, port: Int32)
    /// The requested `SocketAddress` is not supported.
    case unsupported
    /// The requested UDS path is too long.
    case unixDomainSocketPathTooLong
    /// Unable to parse a given IP string
    case failedToParseIPString(String)
}

/// Represent a socket address to which we may want to connect or bind.
public enum SocketAddress: CustomStringConvertible {
    /// A class for creating an immutable box for a structure. Used here to avoid
    /// carrying around a massive sockaddr_un in the enum.
    private final class Box<T> {
        fileprivate let value: T
        fileprivate init(_ value: T) { self.value = value }
    }

    /// A single IPv4 address for `SocketAddress`.
    public struct IPv4Address {
        private let _storage: Box<(address: sockaddr_in, host: String)>

        /// The libc socket address for an IPv4 address.
        public var address: sockaddr_in { return _storage.value.address }

        /// The host this address is for, if known.
        public var host: String { return _storage.value.host }

        fileprivate init(address: sockaddr_in, host: String) {
            self._storage = Box((address: address, host: host))
        }
    }

    /// A single IPv6 address for `SocketAddress`.
    public struct IPv6Address {
        private let _storage: Box<(address: sockaddr_in6, host: String)>

        /// The libc socket address for an IPv6 address.
        public var address: sockaddr_in6 { return _storage.value.address }

        /// The host this address is for, if known.
        public var host: String { return _storage.value.host }

        fileprivate init(address: sockaddr_in6, host: String) {
            self._storage = Box((address: address, host: host))
        }
    }

    /// A single Unix socket address for `SocketAddress`.
    public struct UnixSocketAddress {
        private let _storage: Box<sockaddr_un>

        /// The libc socket address for a Unix Domain Socket.
        public var address: sockaddr_un { return _storage.value }

        fileprivate init(address: sockaddr_un) {
            self._storage = Box(address)
        }
    }

    case v4(IPv4Address)
    case v6(IPv6Address)
    case unixDomainSocket(UnixSocketAddress)

    /// A human-readable description of this `SocketAddress`. Mostly useful for logging.
    public var description: String {
        let port: String
        let host: String?
        let type: String
        switch self {
        case .v4(let addr):
            host = addr.host
            type = "IPv4"
            port = "\(UInt16(bigEndian: addr.address.sin_port))"
        case .v6(let addr):
            host = addr.host
            type = "IPv6"
            port = "\(UInt16(bigEndian: addr.address.sin6_port))"
        case .unixDomainSocket(let addr):
            var address = addr.address
            host = nil
            type = "UDS"
            port = withUnsafeBytes(of: &address.sun_path) { ptr in
                let ptr = ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: 104)
                return String(cString: ptr)
            }
        }
        return "[\(type)]\(host.map { "\($0):" } ?? "")\(port)"
    }
    
    /// Returns the protocol family as defined in `man 2 socket` of this `SocketAddress`.
    public var protocolFamily: Int32 {
        switch self {
        case .v4:
            return PF_INET
        case .v6:
            return PF_INET6
        case .unixDomainSocket:
            return PF_UNIX
        }
    }

    /// Calls the given function with a pointer to a `sockaddr` structure and the associated size
    /// of that structure.
    public func withSockAddr<T>(_ fn: (UnsafePointer<sockaddr>, Int) throws -> T) rethrows -> T {
        switch self {
        case .v4(let addr):
            var address = addr.address
            return try address.withSockAddr(fn)
        case .v6(let addr):
            var address = addr.address
            return try address.withSockAddr(fn)
        case .unixDomainSocket(let addr):
            var address = addr.address
            return try address.withSockAddr(fn)
        }
    }

    /// Creates a new IPV4 `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///       - host: the hostname that resolved to the ipaddress.
    public init(IPv4Address addr: sockaddr_in, host: String) {
        self = .v4(.init(address: addr, host: host))
    }

    /// Creates a new IPV6 `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_in` that holds the ipaddress and port.
    ///       - host: the hostname that resolved to the ipaddress.
    public init(IPv6Address addr: sockaddr_in6, host: String) {
        self = .v6(.init(address: addr, host: host))
    }

    /// Creates a new Unix Domain Socket `SocketAddress`.
    ///
    /// - parameters:
    ///       - addr: the `sockaddr_un` that holds the socket path.
    public init(unixDomainSocket addr: sockaddr_un) {
        self = .unixDomainSocket(.init(address: addr))
    }

    /// Creates a new UDS `SocketAddress`.
    ///
    /// - parameters:
    ///     - path: the path to use for the `SocketAddress`.
    /// - returns: the `SocketAddress` for the given path.
    /// - throws: may throw `SocketAddressError.unixDomainSocketPathTooLong` if the path is too long.
    public static func unixDomainSocketAddress(path: String) throws -> SocketAddress {
        guard path.utf8.count <= 103 else {
            throw SocketAddressError.unixDomainSocketPathTooLong
        }

        let pathBytes = path.utf8 + [0]

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        pathBytes.withUnsafeBufferPointer { srcPtr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { dstPtr in
                    dstPtr.assign(from: srcPtr.baseAddress!, count: pathBytes.count)
                }
            }
        }

        return .unixDomainSocket(.init(address: addr))
    }

    /// Create a new `SocketAddress` for an IP address in string form.
    ///
    /// - parameters:
    ///     - string: The IP address, in string form.
    ///     - port: The target port.
    /// - returns: the `SocketAddress` corresponding to this string and port combination.
    /// - throws: may throw `SocketAddressError.failedToParseIPString` if the IP address cannot be parsed.
    public static func ipAddress(string: String, port: UInt16) throws -> SocketAddress {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return try string.withCString {
            if inet_pton(AF_INET, $0, &ipv4Addr) == 1 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port
                addr.sin_addr = ipv4Addr
                return .v4(.init(address: addr, host: ""))
            } else if inet_pton(AF_INET6, $0, &ipv6Addr) == 1 {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port
                addr.sin6_flowinfo = 0
                addr.sin6_addr = ipv6Addr
                addr.sin6_scope_id = 0
                return .v6(.init(address: addr, host: ""))
            } else {
                throw SocketAddressError.failedToParseIPString(string)
            }
        }
    }

    /// Creates a new `SocketAddress` for the given host (which will be resolved) and port.
    ///
    /// - parameters:
    ///       - host: the hostname which should be resolved.
    ///       - port: the port itself
    /// - returns: the `SocketAddress` for the host / port pair.
    /// - throws: a `SocketAddressError.unknown` if we could not resolve the `host`, or `SocketAddressError.unsupported` if the address itself is not supported (yet).
    public static func newAddressResolving(host: String, port: Int32) throws -> SocketAddress {
        var info: UnsafeMutablePointer<addrinfo>?
        
        /* FIXME: this is blocking! */
        if getaddrinfo(host, String(port), nil, &info) != 0 {
            throw SocketAddressError.unknown(host: host, port: port)
        }
        
        defer {
            if info != nil {
                freeaddrinfo(info)
            }
        }
        
        if let info = info {
            switch info.pointee.ai_family {
            case AF_INET:
                return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                    return .v4(.init(address: ptr.pointee, host: host))
                }
            case AF_INET6:
                return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
                    return .v6(.init(address: ptr.pointee, host: host))
                }
            default:
                throw SocketAddressError.unsupported
            }
        } else {
            /* this is odd, getaddrinfo returned NULL */
            throw SocketAddressError.unsupported
        }
    }
}

