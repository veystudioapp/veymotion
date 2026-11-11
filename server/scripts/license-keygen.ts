// Generates the Ed25519 key pair that signs VeyMotion license tokens.
//   bun run license:keygen
// Put NITRO_LICENSE_PRIVATE_KEY in the server's environment (keep it secret), and the public key in
// Sources/VeyMotionCore/License.swift (`License.publicKeyBase64`). Changing the key signs every user out of Pro
// until their app refreshes, so generate it once.
import { createPublicKey, generateKeyPairSync } from "node:crypto";

const { privateKey } = generateKeyPairSync("ed25519");
const der = privateKey.export({ format: "der", type: "pkcs8" }) as Buffer;
const seed = der.subarray(der.length - 32);
const jwk = createPublicKey(privateKey).export({ format: "jwk" }) as { x: string };

console.log(`NITRO_LICENSE_PRIVATE_KEY=${seed.toString("base64")}`);
console.log(`Public key (License.publicKeyBase64): ${Buffer.from(jwk.x, "base64url").toString("base64")}`);
