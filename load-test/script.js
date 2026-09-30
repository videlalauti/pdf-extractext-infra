import http from "k6/http";
import { check, sleep } from "k6";

const VALIDATION_URL = __ENV.VALIDATION_URL || "http://localhost:8001";
const EXTRACTION_URL = __ENV.EXTRACTION_URL || "http://localhost:8002";
const PERSISTENCE_URL = __ENV.PERSISTENCE_URL || "http://localhost:8003";
const SUMMARY_URL = __ENV.SUMMARY_URL || "http://localhost:8004";
const PDF_PATH = __ENV.PDF_PATH || "../scripts/test.pdf";

const pdf = open(PDF_PATH, "b");

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
    "http_req_duration{name:summary}": ["p(95)<120000"],
  },
};

function buildPdfPayload(boundary) {
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

export default function () {
  const boundary = `----k6boundary${__VU}-${__ITER}-${Date.now()}`;
  const payload = buildPdfPayload(boundary);

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
      timeout: "180s",
    });
    const summaryBody = summary.status === 200 ? JSON.parse(summary.body) : null;
    check(summary, {
      "summary genera resumen no vacio del documento":
        (r) => r.status === 200 && summaryBody?.summary?.length > 0 && summaryBody?.document_id === documentId,
    });
    sleep(0.5);
  }
}

function formatMs(ms) {
  if (typeof ms !== "number" || Number.isNaN(ms)) {
    return "-";
  }
  return `${ms.toFixed(1)} ms`;
}

function line(metric) {
  const v = metric?.values;
  if (!v) {
    return "  (sin datos)";
  }
  const count = typeof v.count === "number" ? v.count : "-";
  return `  count=${count} avg=${formatMs(v.avg)} p(95)=${formatMs(v["p(95)"])} max=${formatMs(v.max)}`;
}

export function handleSummary(data) {
  const report = [];
  report.push("RESUMEN DEL LOAD TEST E2E");
  report.push("==========================");
  report.push("");
  report.push(`Duracion total: ${(data.state.testRunDurationMs / 1000).toFixed(1)} s`);
  const iterInterrupted = data.metrics.iterations_interrupted?.values?.count ?? 0;
  const iterFailed = data.metrics.iterations_failed?.values?.count ?? 0;
  report.push(
    `Iteraciones: ${data.metrics.iterations.values.count} completadas, ${iterInterrupted} interrumpidas, ${iterFailed} fallidas`
  );
  const checks = data.metrics.checks?.values;
  report.push(`Checks: ${checks ? `${checks.passes} pasaron, ${checks.fails} fallaron` : "s/d"}`);
  report.push("");
  report.push("Latencias por endpoint:");
  report.push("  /validate  " + line(data.metrics["http_req_duration{name:validate}"]));
  report.push("  /extract   " + line(data.metrics["http_req_duration{name:extract}"]));
  report.push("  /documents " + line(data.metrics["http_req_duration{name:documents}"]));
  report.push("  /summary   " + line(data.metrics["http_req_duration{name:summary}"]));
  report.push("");
  report.push(`http_req_failed rate: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(3)} %`);
  report.push(`http_reqs totales: ${data.metrics.http_reqs.values.count}`);
  report.push("");

  const text = report.join("\n");
  console.log(text);
  return {
    "results.json": JSON.stringify(data, null, 2),
    "reporte.txt": text,
  };
}