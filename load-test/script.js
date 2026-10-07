import http from "k6/http";
import { check, sleep } from "k6";

const VALIDATION_URL = __ENV.VALIDATION_URL || "http://localhost:8001";
const EXTRACTION_URL = __ENV.EXTRACTION_URL || "http://localhost:8002";
const PERSISTENCE_URL = __ENV.PERSISTENCE_URL || "http://localhost:8003";
const SUMMARY_URL = __ENV.SUMMARY_URL || "http://localhost:8004";
const PDF_PATH = __ENV.PDF_PATH || "../scripts/test.pdf";
const pdfs = (__ENV.PDF_FILES || PDF_PATH)
  .split(",")
  .map((path) => open(path.trim(), "b"));

export const options = {
  scenarios: {
    e2e: {
      // Pocos VUs a proposito: /summary dispara inferencia real de llama3.2
      // (CPU) y el test busca validar el flujo end-to-end bajo carga sostenida,
      // no saturar a Ollama.
      executor: "per-vu-iterations",
      vus: 1,
      iterations: 3,
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.02"],
    "http_req_duration{name:validate}": ["p(95)<500"],
    "http_req_duration{name:extract}": ["p(95)<10000"],
    "http_req_duration{name:documents}": ["p(95)<2000"],
    "http_req_duration{name:summary}": ["p(95)<300000"],
  },
};

function buildPdfPayload(boundary, pdf) {
  const header =
    `--${boundary}\r\n` +
    `Content-Disposition: form-data; name="file"; filename="test.pdf"\r\n` +
    `Content-Type: application/pdf\r\n\r\n`;
  const footer = `\r\n--${boundary}--\r\n`;
  const encoder = new TextEncoder();
  const head = encoder.encode(header);
  const tail = encoder.encode(footer);
  const pdfBytes = new Uint8Array(pdf);
  const body = new Uint8Array(head.length + pdfBytes.length + tail.length);
  body.set(head, 0);
  body.set(pdfBytes, head.length);
  body.set(tail, head.length + pdfBytes.length);
  return body;
}

function postPdf(url, payload, boundary, tagName, timeout) {
  return http.post(url, payload, {
    headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
    tags: { name: tagName },
    timeout,
  });
}

function pollSummary(documentId) {
  // Contrato async: el POST encola (202) y el resultado se consulta con GET
  // hasta que responde 200. El total puede incluir la inferencia real por CPU
  // local (~4-5 min en la primera corrida).
  const deadline = Date.now() + 300000;
  while (Date.now() < deadline) {
    sleep(5);
    const poll = http.get(`${SUMMARY_URL}/summary/${documentId}`, {
      tags: { name: "summary" },
      timeout: "10s",
    });
    if (poll.status === 200) {
      return poll;
    }
    if (poll.status !== 202 && poll.status !== 409) {
      return poll;
    }
  }
  return { status: 408, body: null };
}

export default function () {
  const boundary = `----k6boundary${__VU}-${__ITER}-${Date.now()}`;
  const pdf = pdfs[__ITER % pdfs.length];
  const payload = buildPdfPayload(boundary, pdf);

  const validation = postPdf(
    `${VALIDATION_URL}/validate`,
    payload,
    boundary,
    "validate",
    "10s"
  );
  check(validation, {
    "validate devuelve 200 y valid=true":
      (r) => r.status === 200 && JSON.parse(r.body).valid === true,
  });
  sleep(0.2);

  const extraction = postPdf(
    `${EXTRACTION_URL}/extract`,
    payload,
    boundary,
    "extract",
    "30s"
  );
  check(extraction, {
    "extract devuelve 200 con id y texto":
      (r) => r.status === 200 && !!JSON.parse(r.body).id && !!JSON.parse(r.body).text,
  });
  const documentId = extraction.status === 200 ? JSON.parse(extraction.body).id : null;
  sleep(0.2);

  if (documentId) {
    const document = http.get(`${PERSISTENCE_URL}/documents/${documentId}`, {
      tags: { name: "documents" },
      timeout: "10s",
    });
    const body = document.status === 200 ? JSON.parse(document.body) : null;
    check(document, {
      "documents recupera el documento por id": (r) => r.status === 200 && !!body?.content && !!body?.checksum,
    });
    sleep(0.2);

    const summary = http.post(`${SUMMARY_URL}/summary/${documentId}`, null, {
      tags: { name: "summary" },
      // Compatibilidad doble: con el contrato async el POST responde en ms
      // (202), pero mientras summary sea sincronico la inferencia corre adentro
      // del POST y puede tardar ~200 s. El techo queda en 300 s para que el
      // test sirva antes y despues del cambio; el p95 del tag tambien es 300 s.
      timeout: "300s",
    });
    check(summary, {
      "summary encola (202) o responde directo (200)": (r) =>
        r.status === 202 || r.status === 200,
    });

    // 200 = contrato sincronico (resultado en la misma respuesta); 202 = el
    // resultado se busca por GET. Asi el load test sirve antes y despues de
    // que summary pase a asincrono.
    let summaryResponse = summary;
    if (summary.status === 202) {
      summaryResponse = pollSummary(documentId);
    }
    const summaryBody = summaryResponse.status === 200 ? JSON.parse(summaryResponse.body) : null;
    check(summaryResponse, {
      "summary completa (200 con texto)": (r) =>
        r.status === 200 && summaryBody?.summary?.length > 0 && summaryBody?.document_id === documentId,
    });
    sleep(0.5);
  }
}