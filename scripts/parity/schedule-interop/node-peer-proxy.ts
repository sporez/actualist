import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { chmod, writeFile } from 'node:fs/promises';
import path from 'node:path';

import {
  fromBinary,
  MessageSchema,
  SyncRequestSchema,
  SyncResponseSchema,
} from './actual-crdt-overlay';

export const recordingProxyPort = 5007;

export type ProtocolCapture = {
  sequence: number;
  phase: string;
  requestByteCount: number;
  requestSHA256: string;
  responseByteCount: number;
  responseSHA256: string;
  status: number;
  requestMessageCount: number;
  responseMessageCount: number;
};

export async function startRecordingProxy(
  upstreamOrigin: string,
  evidenceDirectory: string,
  captures: ProtocolCapture[],
  phase: () => string,
) {
  let sequence = 0;
  const server = createServer((request, response) => {
    void forward(request, response).catch(() => {
      if (!response.headersSent) writeJSON(response, 502, { error: 'proxy-failure' });
      else response.destroy();
    });
  });

  async function forward(incoming: IncomingMessage, outgoing: ServerResponse) {
    const requestBody = await readBoundedBody(incoming, 512 * 1024 * 1024);
    const destination = new URL(incoming.url ?? '/', upstreamOrigin);
    assert.equal(destination.origin, upstreamOrigin);
    const headers = new Headers();
    for (const [name, value] of Object.entries(incoming.headers)) {
      if (
        value == null ||
        ['host', 'connection', 'content-length', 'transfer-encoding'].includes(name)
      ) continue;
      if (Array.isArray(value)) value.forEach(item => headers.append(name, item));
      else headers.set(name, value);
    }
    const method = incoming.method ?? 'GET';
    const upstream = await fetch(destination, {
      method,
      headers,
      body: method === 'GET' || method === 'HEAD' ? undefined : requestBody,
      redirect: 'manual',
    });
    const responseBody = Buffer.from(await upstream.arrayBuffer());
    if (destination.pathname === '/sync/sync') {
      sequence += 1;
      const prefix = `sync-${String(sequence).padStart(4, '0')}`;
      await writePrivateFile(path.join(evidenceDirectory, `${prefix}-request.pb`), requestBody);
      await writePrivateFile(path.join(evidenceDirectory, `${prefix}-response.pb`), responseBody);
      const requestTuples = decodeRequestTuples(requestBody);
      const responseTuples = upstream.ok ? decodeResponseTuples(responseBody) : [];
      await writePrivateFile(
        path.join(evidenceDirectory, `${prefix}-decoded.json`),
        Buffer.from(`${JSON.stringify({
          schemaVersion: 1,
          phase: phase(),
          request: requestTuples,
          response: responseTuples,
        }, null, 2)}\n`),
      );
      captures.push({
        sequence,
        phase: phase(),
        requestByteCount: requestBody.length,
        requestSHA256: sha256(requestBody),
        responseByteCount: responseBody.length,
        responseSHA256: sha256(responseBody),
        status: upstream.status,
        requestMessageCount: requestTuples.length,
        responseMessageCount: responseTuples.length,
      });
    }
    const responseHeaders: Record<string, string> = {};
    upstream.headers.forEach((value, name) => {
      if (!['connection', 'content-length', 'transfer-encoding'].includes(name)) {
        responseHeaders[name] = value;
      }
    });
    responseHeaders['content-length'] = String(responseBody.length);
    outgoing.writeHead(upstream.status, responseHeaders);
    outgoing.end(responseBody);
  }

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(recordingProxyPort, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address !== 'string');
  assert.equal(address.address, '127.0.0.1');
  assert.equal(address.port, recordingProxyPort);
  return {
    origin: `http://127.0.0.1:${recordingProxyPort}`,
    close: () => new Promise<void>(resolve => server.close(() => resolve())),
  };
}

async function readBoundedBody(request: IncomingMessage, maximumBytes: number) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    assert.ok(size <= maximumBytes);
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

async function writePrivateFile(file: string, data: Buffer) {
  await writeFile(file, data, { mode: 0o600, flag: 'wx' });
  await chmod(file, 0o600);
}

function writeJSON(response: ServerResponse, status: number, value: unknown) {
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': String(body.length),
    'Cache-Control': 'no-store',
  });
  response.end(body);
}

function decodeRequestTuples(data: Buffer) {
  return fromBinary(SyncRequestSchema, data).messages.map(redactedTuple);
}

function decodeResponseTuples(data: Buffer) {
  return fromBinary(SyncResponseSchema, data).messages.map(redactedTuple);
}

function redactedTuple(envelope: {
  timestamp: string;
  content: Uint8Array;
  isEncrypted: boolean;
}) {
  assert.equal(envelope.isEncrypted, false);
  const message = fromBinary(MessageSchema, envelope.content);
  return {
    timestamp: envelope.timestamp,
    dataset: message.dataset,
    rowHash: sha256(Buffer.from(message.row)),
    column: message.column,
    valueHash: sha256(Buffer.from(message.value)),
  };
}

function sha256(data: Buffer) {
  return createHash('sha256').update(data).digest('hex');
}
