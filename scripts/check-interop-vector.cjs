#!/usr/bin/env node
'use strict';

// Node 22+ / OpenSSL cross-check of the independently generated PechPech v2 fixture.
// Every private input is an openly specified, repeated-byte SYNTHETIC TEST seed.
// Never use these identities or the fixed nonce in an application. No credentials,
// environment variables, runtime stores or external packages are read by this check.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

assert.ok(Number(process.versions.node.split('.')[0]) >= 22, 'Node 22 or later is required.');
const fixturePath = path.join(__dirname, '..', 'Tests', 'PechPechCoreTests', 'Fixtures', 'canonical-v2.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
assert.equal(fixture.syntheticInputs,
  'sender Ed25519 seed=01 repeated 32; sender X25519=02 repeated 32; receiver Ed25519=03 repeated 32; receiver X25519=04 repeated 32; ephemeral X25519=07 repeated 32; AES-GCM nonce=09 repeated 12');
assert.equal(fixture.keyDerivationDomain, 'PECHPECH-2-X25519-HKDF-SHA256-AES256GCM-Ed25519');

function syntheticPrivateKey(kind, byte) {
  const prefix = kind === 'Ed25519' ? '302e020100300506032b657004220420' : '302e020100300506032b656e04220420';
  return crypto.createPrivateKey({
    key: Buffer.concat([Buffer.from(prefix, 'hex'), Buffer.alloc(32, byte)]),
    format: 'der', type: 'pkcs8'
  });
}
function rawPublicKey(privateKey) {
  return crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32);
}
function publicIdentity(signing, agreement) {
  return { signingKey: rawPublicKey(signing).toString('base64'), agreementKey: rawPublicKey(agreement).toString('base64') };
}
function address(identity) {
  return crypto.createHash('sha256').update(Buffer.concat([
    Buffer.from(identity.signingKey, 'base64'), Buffer.from(identity.agreementKey, 'base64')
  ])).digest('hex');
}
// Fixture object keys are ASCII; numbers are safe integers. This is a check of
// these exact protocol bytes, not a general RFC 8785 canonicalization library.
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
  }
  if (typeof value === 'number') assert.ok(Number.isSafeInteger(value));
  return JSON.stringify(value);
}

const senderSigning = syntheticPrivateKey('Ed25519', 1);
const senderAgreement = syntheticPrivateKey('X25519', 2);
const receiverSigning = syntheticPrivateKey('Ed25519', 3);
const receiverAgreement = syntheticPrivateKey('X25519', 4);
const ephemeral = syntheticPrivateKey('X25519', 7);
const senderIdentity = publicIdentity(senderSigning, senderAgreement);
const receiverIdentity = publicIdentity(receiverSigning, receiverAgreement);
assert.equal(canonical(senderIdentity), fixture.senderPublicIdentityJSON);
assert.equal(canonical(receiverIdentity), fixture.receiverPublicIdentityJSON);
assert.equal(address(senderIdentity), fixture.senderAddress);
assert.equal(address(receiverIdentity), fixture.receiverAddress);

const message = {
  id: '00112233-4455-6677-8899-AABBCCDDEEFF', senderID: fixture.senderAddress,
  destinationID: fixture.receiverAddress, channel: 'test/chat',
  payload: Buffer.from('hello / café\n', 'utf8').toString('base64'), createdAt: 1700000000000
};
const expectedHeader = {
  protocolName: 'pechpech', version: 2, packetID: '10213243-5465-7687-98A9-BACBDCEDFE0F',
  destinationID: fixture.receiverAddress, sender: senderIdentity,
  ephemeralKey: rawPublicKey(ephemeral).toString('base64'), priority: 2,
  expiresAt: 1700000060000, hopLimit: 8
};
assert.equal(canonical(message), fixture.messageJSON);
assert.equal(canonical(expectedHeader), fixture.headerJSON);
assert.equal(canonical({ kind: 'message', message }), fixture.endpointEnvelopeJSON);
const packet = JSON.parse(fixture.packetJSON);
assert.equal(canonical(packet), fixture.packetJSON);
assert.deepEqual(packet.header, expectedHeader);
assert.equal(packet.hopsRemaining, 8);

const aad = Buffer.from(fixture.headerJSON, 'utf8');
const expectedEnvelope = Buffer.from(fixture.endpointEnvelopeJSON, 'utf8');
const signatureInput = Buffer.concat([aad, expectedEnvelope]);
assert.equal(signatureInput.toString('utf8'), fixture.signatureInputUTF8);
const signingPublic = crypto.createPublicKey(senderSigning);
assert.ok(crypto.verify(null, signatureInput, signingPublic, Buffer.from(fixture.signatureBase64, 'base64')));

const shared = crypto.diffieHellman({ privateKey: receiverAgreement, publicKey: crypto.createPublicKey(ephemeral) });
assert.deepEqual(shared, crypto.diffieHellman({ privateKey: ephemeral, publicKey: crypto.createPublicKey(receiverAgreement) }));
const key = Buffer.from(crypto.hkdfSync('sha256', shared, Buffer.from(fixture.keyDerivationDomain, 'utf8'), aad, 32));
assert.equal(key.toString('base64'), fixture.derivedKeyBase64);
const combined = Buffer.from(packet.encrypted, 'base64');
assert.deepEqual(combined.subarray(0, 12), Buffer.alloc(12, 9));
const decipher = crypto.createDecipheriv('aes-256-gcm', key, combined.subarray(0, 12));
decipher.setAAD(aad);
decipher.setAuthTag(combined.subarray(-16));
const plain = Buffer.concat([decipher.update(combined.subarray(12, -16)), decipher.final()]);
const signed = JSON.parse(plain.toString('utf8'));
assert.equal(plain.toString('utf8'), canonical(signed));
const envelope = Buffer.from(signed.payload, 'base64');
assert.deepEqual(envelope, expectedEnvelope);
assert.equal(signed.signature, fixture.signatureBase64);
assert.ok(crypto.verify(null, Buffer.concat([aad, envelope]), signingPublic, Buffer.from(signed.signature, 'base64')));
assert.equal(crypto.createHash('sha256').update(Buffer.from(fixture.messageJSON, 'utf8')).digest('base64'), fixture.messageHashBase64);

const unicodeFixture = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'Tests', 'PechPechCoreTests', 'Fixtures', 'unicode-v2.json'), 'utf8'));
assert.equal(unicodeFixture.senderAddress, address(senderIdentity));
assert.equal(unicodeFixture.receiverAddress, address(receiverIdentity));
assert.equal(unicodeFixture.messageID, '00112233-4455-6677-8899-AABBCCDDEEFF');
assert.equal(unicodeFixture.createdAt, '1700000000000');
assert.equal(unicodeFixture.payloadBase64, Buffer.from([1]).toString('base64'));
for (const [name, channel] of [['composed', 'caf\u00e9'], ['decomposed', 'cafe\u0301']]) {
  const unicodeMessage = {
    id: unicodeFixture.messageID, senderID: unicodeFixture.senderAddress,
    destinationID: unicodeFixture.receiverAddress, channel,
    payload: unicodeFixture.payloadBase64, createdAt: Number(unicodeFixture.createdAt)
  };
  const bytes = Buffer.from(canonical(unicodeMessage), 'utf8');
  assert.equal(Buffer.from(channel, 'utf8').toString('hex'), unicodeFixture[name + 'ChannelUTF8Hex']);
  assert.equal(bytes.toString('utf8'), unicodeFixture[name + 'MessageJSON']);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('base64'), unicodeFixture[name + 'MessageHashBase64']);
}
assert.equal('caf\u00e9'.normalize('NFC'), 'cafe\u0301'.normalize('NFC'));
assert.notEqual(unicodeFixture.composedMessageJSON, unicodeFixture.decomposedMessageJSON);
assert.notEqual(unicodeFixture.composedMessageHashBase64, unicodeFixture.decomposedMessageHashBase64);

const opaqueFixture = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'Tests', 'PechPechCoreTests', 'Fixtures', 'opaque-control-v1.json'), 'utf8'));
assert.equal(opaqueFixture.syntheticInputs,
  'Ed25519 seed=11 hex repeated 32; X25519=12 hex repeated 32; immutableHash=13 hex repeated 32');
const opaqueSigning = syntheticPrivateKey('Ed25519', 17);
const opaqueIdentity = publicIdentity(opaqueSigning, syntheticPrivateKey('X25519', 18));
const opaqueAddress = address(opaqueIdentity);
const opaqueProfile = 'com.example.protocol/v1';
const opaqueChallenge = '11111111-1111-4111-8111-111111111111';
const opaqueEcho = '22222222-2222-4222-8222-222222222222';
const opaquePacketID = '33333333-3333-4333-8333-333333333333';
const opaqueHash = Buffer.alloc(32, 19).toString('base64');
const opaqueRoutes = { [opaqueAddress]: 0, ['ab'.repeat(32)]: 2 };
assert.equal(opaqueFixture.publicIdentityJSON, canonical(opaqueIdentity));
assert.equal(opaqueFixture.address, opaqueAddress);
assert.equal(opaqueFixture.profile, opaqueProfile);
assert.equal(opaqueFixture.challenge, opaqueChallenge);
assert.equal(opaqueFixture.echo, opaqueEcho);
assert.equal(opaqueFixture.packetID, opaquePacketID);
assert.equal(opaqueFixture.immutableHashBase64, opaqueHash);
assert.equal(opaqueFixture.routesJSON, canonical(opaqueRoutes));
const opaqueClaims = {
  protocolName: 'pechpech-opaque-link-1', profile: opaqueProfile, identity: opaqueIdentity,
  challenge: opaqueChallenge, echo: opaqueEcho, routes: opaqueRoutes
};
const opaqueClaimsWithoutEcho = { ...opaqueClaims };
delete opaqueClaimsWithoutEcho.echo;
const opaqueAckClaims = {
  protocolName: 'pechpech-opaque-ack-1', profile: opaqueProfile, senderID: opaqueAddress,
  packetID: opaquePacketID, immutableHash: opaqueHash, echo: opaqueEcho
};
for (const [name, claims, kind] of [
  ['hello', opaqueClaims, 'pechpech-opaque-hello'],
  ['helloWithoutEcho', opaqueClaimsWithoutEcho, 'pechpech-opaque-hello'],
  ['ack', opaqueAckClaims, 'pechpech-opaque-stored']
]) {
  const signature = crypto.sign(null, Buffer.from(canonical(claims), 'utf8'), opaqueSigning).toString('base64');
  assert.equal(opaqueFixture[name + 'ClaimsJSON'], canonical(claims));
  assert.equal(opaqueFixture[name + 'SignatureBase64'], signature);
  assert.equal(opaqueFixture[name + 'JSON'], canonical({ kind, claims, signature }));
  assert.ok(crypto.verify(null, Buffer.from(canonical(claims), 'utf8'), crypto.createPublicKey(opaqueSigning), Buffer.from(signature, 'base64')));
}

console.log('PASS: PechPech generic-v2 encryption, Unicode immutable-message and opaque-control-v1 hello/ACK vectors: exact canonical UTF-8 bytes/message hashes, identities/address hashes, Ed25519 signatures, bidirectional X25519 agreement, HKDF-SHA256 and authenticated AES-256-GCM decryption verified with Node/OpenSSL. Synthetic inputs only; no radio or platform implementation claim.');
