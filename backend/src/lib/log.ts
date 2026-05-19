// Структурное логирование. CF Workers Logs ловит console.log/error в JSON.

export function newRid(): string {
  return crypto.randomUUID().slice(0, 8);
}

export function logInfo(fields: Record<string, unknown>): void {
  try {
    console.log(JSON.stringify(fields));
  } catch {
    console.log(String(fields));
  }
}

export function logError(fields: Record<string, unknown>): void {
  try {
    console.error(JSON.stringify(fields));
  } catch {
    console.error(String(fields));
  }
}
