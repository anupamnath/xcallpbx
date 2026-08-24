-- XCall — AI Assistant storage schema (PostgreSQL).
--
-- Stores assistant configurations created in the portal. API keys are NOT
-- stored here in plaintext; the portal encrypts them (AES-256-GCM) before
-- insert. See portal/ai-assistant/assistant_api.php.
--
-- Run as the fusionpbx database user:
--   psql -U fusionpbx -d fusionpbx -f schema.sql

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS v_xcall_assistants (
    assistant_uuid            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    domain_uuid               uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    assistant_name            varchar(255) NOT NULL DEFAULT 'Untitled Assistant',
    assistant_greeting        text,
    assistant_instructions    text,
    assistant_provider        varchar(64)  NOT NULL DEFAULT 'openai',
    assistant_model           varchar(255),
    assistant_api_key_enc     text,
    assistant_api_base_url    varchar(500),
    assistant_temperature     numeric(3,2) DEFAULT 0.7,
    assistant_max_tokens      integer DEFAULT 1024,
    assistant_voice           varchar(64)  DEFAULT 'default',
    assistant_language        varchar(16)  DEFAULT 'en',
    assistant_stt_engine      varchar(32)  DEFAULT 'whisper',
    assistant_tts_engine      varchar(32)  DEFAULT 'piper',
    assistant_handoff_extension varchar(32) DEFAULT '7000',
    assistant_handoff_message text,
    assistant_max_call_seconds integer DEFAULT 900,
    assistant_silence_retries  integer DEFAULT 2,
    assistant_enabled         boolean NOT NULL DEFAULT true,
    assistant_created         timestamptz  NOT NULL DEFAULT now(),
    assistant_updated         timestamptz  NOT NULL DEFAULT now()
);

-- shared secret used by the AI agent to fetch assistant config (set by installer)
CREATE TABLE IF NOT EXISTS v_xcall_settings (
    setting_name  varchar(128) PRIMARY KEY,
    setting_value text
);

INSERT INTO v_xcall_settings (setting_name, setting_value)
VALUES ('agent_shared_secret', encode(gen_random_bytes(32), 'hex'))
ON CONFLICT (setting_name) DO NOTHING;

-- ------------------------------------------------------------------ #
-- XCall company / branding settings (admin panel)
-- One row per domain; holds the system name + company details +
-- softphone customizations. Seeded for the default domain below.
-- ------------------------------------------------------------------ #
CREATE TABLE IF NOT EXISTS v_xcall_company (
    company_uuid            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    domain_uuid             uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    system_name             varchar(255) NOT NULL DEFAULT 'XCall',
    tagline                 varchar(255) NOT NULL DEFAULT 'Cloud PBX',
    logo_path               varchar(500) NOT NULL DEFAULT '/themes/default/images/xcall_logo.svg',
    primary_color           varchar(16)  NOT NULL DEFAULT '#6366f1',
    accent_color            varchar(16)  NOT NULL DEFAULT '#22d3ee',
    company_name            varchar(255) NOT NULL DEFAULT '',
    company_phone           varchar(64)  NOT NULL DEFAULT '',
    company_email           varchar(255) NOT NULL DEFAULT '',
    company_address         text,
    company_website         varchar(255) NOT NULL DEFAULT '',
    softphone_ringtone      varchar(255) NOT NULL DEFAULT 'default',
    softphone_theme         varchar(64)  NOT NULL DEFAULT 'dark',
    softphone_auto_answer   boolean NOT NULL DEFAULT false,
    softphone_hold_music    varchar(255) NOT NULL DEFAULT 'local_stream://moh',
    softphone_enabled       boolean NOT NULL DEFAULT true,
    assistant_default_uuid  uuid,
    company_created         timestamptz  NOT NULL DEFAULT now(),
    company_updated         timestamptz  NOT NULL DEFAULT now()
);

INSERT INTO v_xcall_company (domain_uuid, system_name, tagline)
SELECT '00000000-0000-0000-0000-000000000000', 'XCall', 'Cloud PBX'
WHERE NOT EXISTS (SELECT 1 FROM v_xcall_company WHERE domain_uuid = '00000000-0000-0000-0000-000000000000');

-- ------------------------------------------------------------------ #
-- Client directory (admin panel CRM)
-- ------------------------------------------------------------------ #
CREATE TABLE IF NOT EXISTS v_xcall_clients (
    client_uuid     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    domain_uuid     uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    client_name     varchar(255) NOT NULL DEFAULT '',
    client_phone    varchar(64)  NOT NULL DEFAULT '',
    client_email    varchar(255) NOT NULL DEFAULT '',
    client_company  varchar(255) NOT NULL DEFAULT '',
    client_notes    text,
    client_status   varchar(32)  NOT NULL DEFAULT 'active',
    client_created  timestamptz  NOT NULL DEFAULT now(),
    client_updated  timestamptz  NOT NULL DEFAULT now()
);

