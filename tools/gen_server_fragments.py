#!/usr/bin/env python3
"""根据服务端 X25519 公钥，生成 V2Protocol.swift 里的内嵌分片常量。

V2Protocol 不再直接写公钥明文，而是拆成 4 段 × 8 字节，每段与一个随机 mask
以及 (i*7+0x31) 异或后内嵌；解码函数 decode() 负责还原。改密钥时执行本脚本，
把输出整段替换 V2Protocol.swift 里 `private static let f0` … `private static let fpB`
之间的内容。

用法：
    python tools/gen_server_fragments.py <服务端公钥hex(64字符)>
    python tools/gen_server_fragments.py            # 从 tools/secrets.json 读不到，需显式传参

公钥来源可以是：
    - 服务端 config/secret.ts 里的 appProtocol.publicKeyHex
    - tools/server_keys.json
"""
import hashlib
import secrets
import sys


def swift_bytes(data: bytes) -> str:
    return "[" + ", ".join("0x%02x" % b for b in data) + "]"


def build(pub: bytes) -> str:
    if len(pub) != 32:
        raise SystemExit("公钥必须是 32 字节（64 个 hex 字符）")

    masks = [secrets.randbelow(256) for _ in range(4)]
    encoded = []
    for slot in range(4):
        part = pub[slot * 8:(slot + 1) * 8]
        encoded.append([part[i] ^ masks[slot] ^ ((i * 7 + 0x31) & 0xFF) for i in range(8)])

    digest = hashlib.sha256(pub).digest()
    fp_a = [digest[0] ^ 0x6D, digest[1] ^ 0x6D]
    fp_b = [digest[2] ^ 0xB4, digest[3] ^ 0xB4]

    lines = []
    for i in range(4):
        lines.append("    private static let f%d: [UInt8] = %s" % (i, swift_bytes(encoded[i])))
    lines.append("")
    for i in range(4):
        lines.append("    private static let m%d: UInt8 = 0x%02x" % (i, masks[i]))
    lines.append("")
    lines.append("    /// sha256(pubkey)[0..4]，拆两段各自异或")
    lines.append("    private static let fpA: [UInt8] = %s" % swift_bytes(fp_a))
    lines.append("    private static let fpB: [UInt8] = %s" % swift_bytes(fp_b))
    lines.append("")
    lines.append("    /// 校验：decode 后应等于 %s" % pub.hex())
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    pub = bytes.fromhex(sys.argv[1].strip())
    print(build(pub))
    return 0


if __name__ == "__main__":
    sys.exit(main())
