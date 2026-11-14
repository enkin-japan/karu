interface ServerConfig { port?: number; tls?: { cert: string } }
interface AppConfig { server?: ServerConfig; name: string }

export function describe(config: AppConfig): string {
  const port = config?.server?.‸
  return `${config.name}:${port}`;
}

export function hasTls(config: AppConfig) {
  return config.server?.tls !== undefined;
}

export function portOf(config: AppConfig) {
  return config.server?.port ?? 80;
}
