declare module "cloudflare:test" {
  interface ProvidedEnv {
    DB: D1Database;
    ROOM: DurableObjectNamespace;
    TEST_MIGRATIONS: D1Migration[];
    APNS_TEAM_ID: string;
    APNS_KEY_ID: string;
    APNS_BUNDLE_ID: string;
    APNS_HOST: string;
    APNS_KEY: string;
  }
}
