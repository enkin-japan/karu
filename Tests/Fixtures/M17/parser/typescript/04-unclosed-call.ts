import { fetchJson } from "./http";

const BASE_URL = "https://api.example.com";

export async function getInvoice(id: string, locale = "en") {
  const url = `${BASE_URL}/invoices/${id}`;
  const invoice = await fetchJson(url, {
    headers: { "Accept-Language": locale },
  ‸
  return invoice;
}

export function formatId(id: string) {
  return id.padStart(8, "0");
}
