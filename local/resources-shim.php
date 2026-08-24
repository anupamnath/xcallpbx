<?php
/**
 * XCall — LOCAL DEV SHIM (resources/require.php)
 * ----------------------------------------------
 * Stand-in for FusionPBX's resources/require.php so the XCall portal
 * pages (AI Assistants, Web Softphone) can be previewed on a dev
 * machine using PHP's built-in server + SQLite.
 *
 * NOT for production. The real deployment uses FusionPBX's own
 * require.php and PostgreSQL. This file is copied into place by
 * local/start-demo.bat and is gitignored.
 */

// ---- session: auto-login a demo admin so pages pass the auth gate ----
session_start();

if (empty($_SESSION['username'])) {
    $_SESSION['username']              = 'admin';
    $_SESSION['domain_uuid']           = '00000000-0000-0000-0000-000000000000';
    $_SESSION['domain_name']           = 'xcall.local';
    $_SESSION['extension']             = '1000';
    $_SESSION['user_caller_id_name']   = 'XCall Admin';
    $_SESSION['user_caller_id_number'] = '1000';
}

if (!defined('PROJECT_PATH')) {
    define('PROJECT_PATH', '');
}

// ---- minimal `settings` facade (used by webphone/config.php) ----
if (!class_exists('settings')) {
    class settings
    {
        public function __construct(array $options = []) {}
        public function get(string $category, string $subcategory, string $default = ''): string
        {
            return $default; // local demo: no domain settings, use defaults
        }
    }
}

// ---- minimal SQLite-backed database facade ----
// Matches the FusionPBX methods used by the portal pages:
//   $database->select($sql, $params, 'all' | 'row' | 'var')
//   $database->execute($sql, $params)
if (!class_exists('XCallLocalDatabase')) {
    class XCallLocalDatabase
    {
        private PDO $pdo;

        public function __construct(string $dbfile)
        {
            $dir = dirname($dbfile);
            if (!is_dir($dir)) {
                mkdir($dir, 0777, true);
            }
            $this->pdo = new PDO('sqlite:' . $dbfile, null, null, [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            ]);
            $this->initSchema();
        }

        private function initSchema(): void
        {
            $this->pdo->exec("CREATE TABLE IF NOT EXISTS v_xcall_assistants (
                assistant_uuid              TEXT PRIMARY KEY,
                domain_uuid                 TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
                assistant_name              TEXT NOT NULL DEFAULT 'Untitled Assistant',
                assistant_greeting          TEXT,
                assistant_instructions      TEXT,
                assistant_provider          TEXT NOT NULL DEFAULT 'openai',
                assistant_model             TEXT,
                assistant_api_key_enc       TEXT,
                assistant_api_base_url      TEXT,
                assistant_temperature       REAL DEFAULT 0.7,
                assistant_max_tokens        INTEGER DEFAULT 1024,
                assistant_voice             TEXT DEFAULT 'default',
                assistant_language          TEXT DEFAULT 'en',
                assistant_stt_engine        TEXT DEFAULT 'whisper',
                assistant_tts_engine        TEXT DEFAULT 'piper',
                assistant_handoff_extension TEXT DEFAULT '7000',
                assistant_handoff_message   TEXT,
                assistant_max_call_seconds  INTEGER DEFAULT 900,
                assistant_silence_retries   INTEGER DEFAULT 2,
                assistant_enabled           INTEGER NOT NULL DEFAULT 1,
                assistant_created           TEXT NOT NULL DEFAULT (datetime('now')),
                assistant_updated           TEXT NOT NULL DEFAULT (datetime('now'))
            )");
            $this->pdo->exec("CREATE TABLE IF NOT EXISTS v_xcall_settings (
                setting_name  TEXT PRIMARY KEY,
                setting_value TEXT
            )");

            // v_xcall_company — system/company branding + softphone settings
            $this->pdo->exec("CREATE TABLE IF NOT EXISTS v_xcall_company (
                company_uuid  TEXT PRIMARY KEY,
                domain_uuid   TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
                system_name   TEXT NOT NULL DEFAULT 'XCall',
                tagline       TEXT NOT NULL DEFAULT 'Cloud PBX',
                logo_path     TEXT NOT NULL DEFAULT '/themes/default/images/xcall_logo.svg',
                primary_color TEXT NOT NULL DEFAULT '#6366f1',
                accent_color  TEXT NOT NULL DEFAULT '#22d3ee',
                company_name  TEXT NOT NULL DEFAULT '',
                company_phone TEXT NOT NULL DEFAULT '',
                company_email TEXT NOT NULL DEFAULT '',
                company_address TEXT,
                company_website TEXT NOT NULL DEFAULT '',
                softphone_ringtone TEXT NOT NULL DEFAULT 'default',
                softphone_theme TEXT NOT NULL DEFAULT 'dark',
                softphone_auto_answer TEXT NOT NULL DEFAULT 'false',
                softphone_hold_music TEXT NOT NULL DEFAULT 'local_stream://moh',
                softphone_enabled TEXT NOT NULL DEFAULT 'true',
                assistant_default_uuid TEXT,
                company_created TEXT NOT NULL DEFAULT (datetime('now')),
                company_updated TEXT NOT NULL DEFAULT (datetime('now'))
            )");
            $st = $this->pdo->query("SELECT COUNT(*) FROM v_xcall_company WHERE domain_uuid = '00000000-0000-0000-0000-000000000000'");
            if ((int)$st->fetchColumn() === 0) {
                $ins = $this->pdo->prepare('INSERT INTO v_xcall_company (company_uuid, domain_uuid) VALUES (?, ?)');
                $ins->execute(['00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000']);
            }

            // v_xcall_clients — admin panel client directory
            $this->pdo->exec("CREATE TABLE IF NOT EXISTS v_xcall_clients (
                client_uuid   TEXT PRIMARY KEY,
                domain_uuid   TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
                client_name   TEXT NOT NULL DEFAULT '',
                client_phone  TEXT NOT NULL DEFAULT '',
                client_email  TEXT NOT NULL DEFAULT '',
                client_company TEXT NOT NULL DEFAULT '',
                client_notes  TEXT,
                client_status TEXT NOT NULL DEFAULT 'active',
                client_created TEXT NOT NULL DEFAULT (datetime('now')),
                client_updated TEXT NOT NULL DEFAULT (datetime('now'))
            )");

            // minimal v_default_settings so the admin "system name" push works
            $this->pdo->exec("CREATE TABLE IF NOT EXISTS v_default_settings (
                default_setting_uuid TEXT PRIMARY KEY,
                default_setting_category TEXT,
                default_setting_subcategory TEXT,
                default_setting_value TEXT
            )");
            $ins = $this->pdo->prepare(
                "INSERT OR IGNORE INTO v_default_settings
                 (default_setting_uuid, default_setting_category, default_setting_subcategory, default_setting_value)
                 VALUES (?, 'theme', 'menu_brand_text', 'XCall')"
            );
            $ins->execute(['00000000-0000-0000-0000-000000000010']);

            // minimal v_users table so webphone/config.php works in the demo
            $this->pdo->exec("CREATE TABLE IF NOT EXISTS v_users (
                user_uuid TEXT PRIMARY KEY,
                domain_uuid TEXT,
                username TEXT,
                extension TEXT,
                user_password TEXT,
                user_caller_id_name TEXT,
                user_caller_id_number TEXT,
                user_enabled TEXT
            )");
            $st = $this->pdo->query("SELECT COUNT(*) FROM v_users WHERE username = 'admin'");
            if ((int)$st->fetchColumn() === 0) {
                $ins = $this->pdo->prepare('INSERT INTO v_users
                    (user_uuid, domain_uuid, username, extension, user_password, user_caller_id_name, user_caller_id_number, user_enabled)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
                $ins->execute([
                    '00000000-0000-0000-0000-000000000001',
                    '00000000-0000-0000-0000-000000000000',
                    'admin', '1000', 'local-demo-pass',
                    'XCall Admin', '1000', 'true',
                ]);
            }

            // seed a shared secret for the agent_config endpoint
            $st = $this->pdo->query("SELECT COUNT(*) FROM v_xcall_settings WHERE setting_name = 'agent_shared_secret'");
            if ((int)$st->fetchColumn() === 0) {
                $secret = bin2hex(random_bytes(16));
                $ins = $this->pdo->prepare('INSERT INTO v_xcall_settings (setting_name, setting_value) VALUES (?, ?)');
                $ins->execute(['agent_shared_secret', $secret]);
            }
        }

        private function prepare(string $sql): PDOStatement
        {
            // translate a couple of Postgres idioms to SQLite
            $sql = preg_replace('/\bnow\(\)/i', "datetime('now')", $sql);
            // the API stores booleans as text ('true'/'false'); make Postgres-style
            // `= true` / `= false` comparisons match in SQLite.
            $sql = preg_replace('/=\s*true\b/i', "= 'true'", $sql);
            $sql = preg_replace('/=\s*false\b/i', "= 'false'", $sql);
            return $this->pdo->prepare($sql);
        }

        private function castRow(?array $row): ?array
        {
            if ($row === null) {
                return null;
            }
            // Postgres returns booleans as PHP bools; make SQLite match.
            if (array_key_exists('assistant_enabled', $row)) {
                $v = $row['assistant_enabled'];
                $row['assistant_enabled'] = ($v === true || $v === 't' || $v === '1' || $v === 'true' || $v === 1);
            }
            return $row;
        }

        public function select(string $sql, array $params = [], string $type = 'all')
        {
            $stmt = $this->prepare($sql);
            $stmt->execute($params);
            if ($type === 'var') {
                return $stmt->fetchColumn();
            }
            if ($type === 'row') {
                $row = $stmt->fetch();
                return $this->castRow($row === false ? null : $row);
            }
            $rows = $stmt->fetchAll();
            return array_map([$this, 'castRow'], $rows);
        }

        public function execute(string $sql, array $params = []): void
        {
            // the API inserts new rows without a uuid; Postgres fills it via
            // gen_random_uuid() — inject the column + placeholder here for SQLite.
            $tables = [
                "v_xcall_assistants" => "assistant_uuid",
                "v_xcall_company"    => "company_uuid",
                "v_xcall_clients"    => "client_uuid",
            ];
            $lower = ltrim(strtolower($sql));
            foreach ($tables as $table => $col) {
                if (strpos($lower, "insert into $table") === 0 && stripos($sql, $col) === false) {
                    $sql = preg_replace(
                        ['/^(\s*insert\s+into\s+' . $table . '\s*\()/i', '/\bvalues\s*\(/i'],
                        ['$1' . $col . ', ', 'values (:' . $col . ', '],
                        $sql,
                        1
                    );
                    $params[$col] = sprintf(
                        '%s-%s-%s-%s-%s',
                        bin2hex(random_bytes(4)),
                        bin2hex(random_bytes(2)),
                        bin2hex(random_bytes(2)),
                        bin2hex(random_bytes(2)),
                        bin2hex(random_bytes(6))
                    );
                    break;
                }
            }
            $stmt = $this->prepare($sql);
            $stmt->execute($params);
        }
    }
}

// ---- shared database handle (demo DB lives under local/) ----
$database = new XCallLocalDatabase(dirname(__DIR__) . '/local/xcall_demo.sqlite');

