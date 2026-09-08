#!/usr/bin/env swift
// scripts/sign-release.swift
// 사용법: swift scripts/sign-release.swift <Wattly.zip> [개인키 경로]
// <Wattly.zip>.sig 에 base64 Ed25519 서명을 쓰고, 방금 쓴 서명을 공개키로 다시 검증한다.
import CryptoKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let archivePath = args.first else {
    FileHandle.standardError.write(Data("usage: sign-release.swift <archive> [keyfile]\n".utf8))
    exit(64)
}
let keyPath = args.count > 1
    ? args[1]
    : NSString(string: "~/.wattly/update-signing.key").expandingTildeInPath

guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("cannot read private key at \(keyPath)\n".utf8))
    exit(66)
}

let archive = try Data(contentsOf: URL(fileURLWithPath: archivePath))
let signature = try key.signature(for: archive)
let signaturePath = archivePath + ".sig"
try (signature.base64EncodedString() + "\n").write(toFile: signaturePath, atomically: true, encoding: .utf8)

guard key.publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("self-check failed\n".utf8))
    exit(70)
}
print("signed \(archivePath) -> \(signaturePath)")
print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
