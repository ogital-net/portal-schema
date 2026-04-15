-- =============================================================================
-- V2: Data Circuits, Carriers, and Carrier Accounts
--
-- Models the Layer 1 / Layer 2 access circuits that bring internet
-- connectivity to each property, along with the carrier relationships
-- underpinning them.
--
-- Tables (in dependency order):
--   carriers          — carrier/telco companies, tenant-scoped
--   carrier_contacts  — escalation contact directory per carrier
--   carrier_accounts  — billing/MSA account a tenant holds with a carrier
--   data_circuits     — individual access circuit at a property
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enum Types
-- ---------------------------------------------------------------------------

-- Logical service type of the circuit from the carrier
CREATE TYPE circuit_type AS ENUM (
    'dedicated_internet_access',  -- DIA: symmetric fiber internet
    'ethernet_private_line',      -- EPL: point-to-point L2 circuit
    'ethernet_vpls',              -- VPLS / multipoint Ethernet
    'cable_modem',                -- DOCSIS cable broadband
    'gpon',                       -- Gigabit Passive Optical Network (shared)
    'xgs_pon',                    -- 10G symmetric PON
    'fiber_broadband',            -- consumer/SMB symmetric fiber (non-DIA)
    'dsl',                        -- xDSL (ADSL2+, VDSL2, etc.)
    'fixed_wireless',             -- licensed or unlicensed fixed wireless
    'mpls',                       -- MPLS L3VPN
    'dark_fiber',                 -- Indefeasible Right of Use (IRU) dark fiber
    'sd_wan',                     -- carrier-managed SD-WAN overlay
    'docsis_business',            -- business-class DOCSIS (distinct SLA from cable_modem)
    'other'
);

-- Physical access medium
CREATE TYPE circuit_media AS ENUM (
    'fiber_smf',            -- single-mode fiber
    'fiber_mmf',            -- multimode fiber
    'coax',                 -- coaxial cable
    'copper_twisted_pair',  -- DSL / Ethernet over copper
    'licensed_wireless',    -- microwave / mmWave (licensed band)
    'unlicensed_wireless',  -- CBRS / ISM band
    'dark_fiber',           -- unlit fiber (IRU)
    'other'
);

-- Transceiver / optic type at the demarcation port
CREATE TYPE handoff_interface AS ENUM (
    -- Copper (no optic)
    'rj45',                 -- 10/100/1000BASE-T copper
    'rj45_10g',             -- 10GBASE-T copper

    -- 1G SFP optics
    'sfp_1g_sx',            -- 1000BASE-SX  (850 nm, MMF, ~550 m)
    'sfp_1g_lx',            -- 1000BASE-LX  (1310 nm, SMF, ~10 km)
    'sfp_1g_lh',            -- 1000BASE-LH  (1310 nm, SMF, ~40 km)
    'sfp_1g_zx',            -- 1000BASE-ZX  (1550 nm, SMF, ~70 km)
    'sfp_1g_bx_d',          -- 1000BASE-BX10-D  BiDi downstream
    'sfp_1g_bx_u',          -- 1000BASE-BX10-U  BiDi upstream
    'sfp_1g_t',             -- 1000BASE-T copper SFP

    -- 10G SFP+ optics
    'sfp_plus_10g_sr',      -- 10GBASE-SR   (850 nm, MMF, ~300 m)
    'sfp_plus_10g_lr',      -- 10GBASE-LR   (1310 nm, SMF, ~10 km)
    'sfp_plus_10g_er',      -- 10GBASE-ER   (1550 nm, SMF, ~40 km)
    'sfp_plus_10g_zr',      -- 10GBASE-ZR   (1550 nm, SMF, ~80 km)
    'sfp_plus_10g_lrm',     -- 10GBASE-LRM  (1310 nm, MMF, ~220 m)
    'sfp_plus_10g_t',       -- 10GBASE-T copper SFP+
    'sfp_plus_10g_bx_d',    -- 10GBASE-BX-D BiDi downstream
    'sfp_plus_10g_bx_u',    -- 10GBASE-BX-U BiDi upstream

    -- 25G SFP28 optics
    'sfp28_25g_sr',         -- 25GBASE-SR   (850 nm, MMF, ~100 m)
    'sfp28_25g_lr',         -- 25GBASE-LR   (1310 nm, SMF, ~10 km)
    'sfp28_25g_er',         -- 25GBASE-ER   (1550 nm, SMF, ~40 km)
    'sfp28_25g_bx_d',       -- 25GBASE-BX-D BiDi downstream
    'sfp28_25g_bx_u',       -- 25GBASE-BX-U BiDi upstream

    -- 40G QSFP+ optics
    'qsfp_plus_40g_sr4',    -- 40GBASE-SR4  (850 nm, MMF, ~100 m, 8-fiber MTP)
    'qsfp_plus_40g_lr4',    -- 40GBASE-LR4  (CWDM 1310 nm, SMF, ~10 km, LC duplex)
    'qsfp_plus_40g_er4',    -- 40GBASE-ER4  (CWDM 1310 nm, SMF, ~40 km)
    'qsfp_plus_40g_psm4',   -- 40GBASE-PSM4 (1310 nm, SMF, ~500 m, 8-fiber MTP)

    -- 100G QSFP28 optics
    'qsfp28_100g_sr4',      -- 100GBASE-SR4  (850 nm, MMF, ~100 m, 8-fiber MTP)
    'qsfp28_100g_lr4',      -- 100GBASE-LR4  (CWDM 1310 nm, SMF, ~10 km, LC duplex)
    'qsfp28_100g_er4',      -- 100GBASE-ER4  (CWDM 1310 nm, SMF, ~40 km)
    'qsfp28_100g_zr',       -- 100GBASE-ZR   (1550 nm coherent, SMF, ~80 km)
    'qsfp28_100g_fr1',      -- 100GBASE-FR1  (1310 nm, SMF, ~2 km, LC simplex)
    'qsfp28_100g_lr1',      -- 100GBASE-LR1  (O-band, SMF, ~10 km, LC simplex)
    'qsfp28_100g_psm4',     -- 100GBASE-PSM4 (1310 nm, SMF, ~500 m, 8-fiber MTP)
    'qsfp28_100g_cwdm4',    -- 100GBASE-CWDM4 (CWDM, SMF, ~2 km)

    -- 400G QSFP-DD / OSFP optics
    'qsfp_dd_400g_sr8',     -- 400GBASE-SR8  (850 nm, MMF, ~100 m, 16-fiber MTP)
    'qsfp_dd_400g_dr4',     -- 400GBASE-DR4  (1310 nm, SMF, ~500 m, 8-fiber MTP)
    'qsfp_dd_400g_fr4',     -- 400GBASE-FR4  (CWDM 1310 nm, SMF, ~2 km, LC duplex)
    'qsfp_dd_400g_lr4',     -- 400GBASE-LR4  (CWDM 1310 nm, SMF, ~10 km, LC duplex)
    'qsfp_dd_400g_er8',     -- 400GBASE-ER8  (1550 nm, SMF, ~40 km)
    'qsfp_dd_400g_zr',      -- 400ZR          (1550 nm coherent, SMF, ~80–120 km)
    'qsfp_dd_400g_zro',     -- 400ZR+         (extended coherent, SMF, ~120+ km)

    -- Coax
    'f_connector',          -- DOCSIS / cable modem F-type coax

    'other'
);

-- Physical fiber or copper connector at the demarcation
CREATE TYPE handoff_connector AS ENUM (
    -- Single-fiber connectors (duplex pairs most common)
    'lc_upc',       -- LC/UPC   — most common SMF, blue boot
    'lc_apc',       -- LC/APC   — angled, green boot, lower back-reflection
    'sc_upc',       -- SC/UPC   — push-pull, blue boot
    'sc_apc',       -- SC/APC   — angled, green boot
    'fc_upc',       -- FC/UPC   — threaded, legacy carrier/telco
    'fc_apc',       -- FC/APC   — threaded, angled
    'st_upc',       -- ST/UPC   — bayonet, legacy
    'e2000_apc',    -- E-2000/APC — spring-loaded shutter (common in Europe)
    'mtrj',         -- MT-RJ    — duplex small-form, often MMF
    'mu',           -- MU       — miniature, high-density panels

    -- Multi-fiber array connectors (MTP/MPO)
    'mtp_mpo_8',    -- MTP/MPO 8-fiber  (1×8, single-mode)
    'mtp_mpo_12',   -- MTP/MPO 12-fiber (1×12, most common)
    'mtp_mpo_16',   -- MTP/MPO 16-fiber (1×16)
    'mtp_mpo_24',   -- MTP/MPO 24-fiber (2×12, high-density)
    'mtp_mpo_32',   -- MTP/MPO 32-fiber (2×16)

    -- Copper / coax
    'rj45',         -- RJ-45 copper
    'f_type',       -- F-type coax (DOCSIS / cable)
    'bnc',          -- BNC coax (legacy)

    'other'
);

-- Lifecycle state of the circuit
CREATE TYPE circuit_status AS ENUM (
    'ordering',       -- LOA / order submitted to carrier
    'provisioning',   -- carrier confirmed, install in progress
    'active',         -- carrying live traffic
    'impaired',       -- degraded / partial outage, carrier ticket open
    'down',           -- full outage, carrier ticket open
    'maintenance',    -- inside a carrier-scheduled maintenance window
    'suspended',      -- billing hold or voluntary suspension
    'cancelled'       -- decommissioned / cancelled
);

-- Contact role within a carrier organisation
CREATE TYPE carrier_contact_role AS ENUM (
    'noc_tier1',        -- 24/7 first-line NOC
    'noc_tier2',        -- escalation / engineering NOC
    'noc_tier3',        -- senior escalation
    'account_manager',  -- commercial account manager
    'billing',          -- billing / invoice queries
    'provisioning',     -- new order / project manager
    'emergency',        -- after-hours emergency contact
    'other'
);

-- ---------------------------------------------------------------------------
-- carriers
-- A telco, CLEC, ILEC, cable operator, or transit provider that delivers
-- circuits to the tenant's properties.  Scoped to a tenant because different
-- ISPs have different carrier partners, pricing, and account structures.
-- ---------------------------------------------------------------------------
CREATE TABLE carriers (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,

    -- Identity
    name        TEXT        NOT NULL,   -- e.g. "Lumen Technologies"
    short_name  TEXT,                   -- e.g. "Lumen"
    website     TEXT,

    -- Carrier industry identifiers
    ocn         TEXT,   -- Operating Company Number (FCC-issued, 4-char alphabetic)
    asr_prefix  TEXT,   -- Access Service Request prefix used on orders

    -- 24/7 Network Operations Center (primary)
    noc_phone       TEXT,
    noc_email       CITEXT,
    noc_portal_url  TEXT,   -- carrier's online trouble-ticket portal URL
    noc_chat_url    TEXT,   -- carrier's online chat / real-time support URL

    -- Escalation NOC (typically Tier 2 / engineering)
    escalation_phone    TEXT,
    escalation_email    CITEXT,

    -- Provisioning / new orders desk
    provisioning_phone  TEXT,
    provisioning_email  CITEXT,
    provisioning_portal_url TEXT,

    -- Billing
    billing_phone   TEXT,
    billing_email   CITEXT,
    billing_portal_url TEXT,

    -- Standard SLAs offered by this carrier (advisory; circuit-level SLA
    -- fields override these when present)
    standard_mttr_hours     NUMERIC(5,2),   -- guaranteed mean time to repair (hours)
    standard_uptime_percent NUMERIC(6,4),   -- e.g. 99.9900

    notes   TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_carriers_uuid        UNIQUE (uuid),
    CONSTRAINT uq_carriers_tenant_name UNIQUE (tenant_id, name),

    CONSTRAINT fk_carriers_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_carriers_tenant_id  ON carriers (tenant_id);
CREATE INDEX idx_carriers_deleted_at ON carriers (deleted_at);

CREATE TRIGGER trg_carriers_set_updated_at
    BEFORE UPDATE ON carriers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- carrier_contacts
-- Extensible directory of named contacts at a carrier, organised by role.
-- Supports arbitrary escalation chains (Tier-1 → Tier-2 → Tier-3 → VP) and
-- specialised contacts (billing, provisioning project managers, etc.).
-- ---------------------------------------------------------------------------
CREATE TABLE carrier_contacts (
    id          BIGSERIAL               PRIMARY KEY,
    uuid        UUID                    NOT NULL DEFAULT uuidv7(),
    carrier_id  BIGINT                  NOT NULL,
    tenant_id   BIGINT                  NOT NULL,

    role        carrier_contact_role    NOT NULL,

    -- Contact details
    name        TEXT,                   -- individual name or team name
    title       TEXT,                   -- job title
    phone       TEXT,
    mobile      TEXT,
    email       CITEXT,
    notes       TEXT,

    -- Display order within the same role for this carrier (lower = higher priority)
    priority    SMALLINT    NOT NULL DEFAULT 0,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_carrier_contacts_uuid UNIQUE (uuid),

    CONSTRAINT fk_carrier_contacts_carrier
        FOREIGN KEY (carrier_id)
        REFERENCES carriers (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_carrier_contacts_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_carrier_contacts_carrier_id ON carrier_contacts (carrier_id);
CREATE INDEX idx_carrier_contacts_tenant_id  ON carrier_contacts (tenant_id);
CREATE INDEX idx_carrier_contacts_role       ON carrier_contacts (role);
CREATE INDEX idx_carrier_contacts_deleted_at ON carrier_contacts (deleted_at);

CREATE TRIGGER trg_carrier_contacts_set_updated_at
    BEFORE UPDATE ON carrier_contacts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- carrier_accounts
-- The commercial/billing account a tenant holds with a carrier.  A tenant
-- may have more than one account with the same carrier (e.g. separate
-- accounts for different regions or business units).
--
-- Individual circuits reference a carrier_account so billing and escalation
-- can be tied to the correct account when a ticket is opened.
-- ---------------------------------------------------------------------------
CREATE TABLE carrier_accounts (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    carrier_id  BIGINT      NOT NULL,

    -- Carrier-issued account number or customer ID
    account_number  TEXT    NOT NULL,

    -- Human label to distinguish multiple accounts with the same carrier
    label           TEXT,   -- e.g. "Northeast Region", "Corporate HQ"

    -- Master Services Agreement
    msa_reference   TEXT,   -- MSA or contract document number
    msa_start_date  DATE,
    msa_end_date    DATE,   -- NULL = evergreen

    -- Dedicated account manager (may duplicate carrier_contacts data for
    -- convenience; the source of truth is carrier_contacts)
    account_manager_name    TEXT,
    account_manager_phone   TEXT,
    account_manager_email   CITEXT,

    -- Billing address (if different from tenant address)
    billing_address_line1   TEXT,
    billing_address_line2   TEXT,
    billing_city            TEXT,
    billing_state           TEXT,
    billing_postal_code     TEXT,
    billing_country         TEXT DEFAULT 'US',

    -- Billing cycle day-of-month (1–28)
    billing_cycle_day   SMALLINT    CHECK (billing_cycle_day BETWEEN 1 AND 28),

    -- Credit / financial
    credit_limit_usd    NUMERIC(12,2),

    notes   TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_carrier_accounts_uuid                    UNIQUE (uuid),
    CONSTRAINT uq_carrier_accounts_tenant_carrier_account  UNIQUE (tenant_id, carrier_id, account_number),

    CONSTRAINT fk_carrier_accounts_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_carrier_accounts_carrier
        FOREIGN KEY (carrier_id)
        REFERENCES carriers (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_carrier_accounts_tenant_id  ON carrier_accounts (tenant_id);
CREATE INDEX idx_carrier_accounts_carrier_id ON carrier_accounts (carrier_id);
CREATE INDEX idx_carrier_accounts_deleted_at ON carrier_accounts (deleted_at);

CREATE TRIGGER trg_carrier_accounts_set_updated_at
    BEFORE UPDATE ON carrier_accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- data_circuits
-- One row per physical or logical access circuit delivering internet (or
-- private WAN) connectivity to a property.  A property may have multiple
-- circuits for redundancy or diverse path protection.
-- ---------------------------------------------------------------------------
CREATE TABLE data_circuits (
    id                  BIGSERIAL           PRIMARY KEY,
    uuid                UUID                NOT NULL DEFAULT uuidv7(),
    tenant_id           BIGINT              NOT NULL,
    property_id         BIGINT              NOT NULL,
    carrier_id          BIGINT              NOT NULL,
    carrier_account_id  BIGINT              NOT NULL,

    -- -------------------------------------------------------------------------
    -- Identity
    -- -------------------------------------------------------------------------
    -- Carrier-issued circuit identifier (appears on LOAs, invoices, tickets)
    carrier_circuit_id  TEXT                NOT NULL,

    -- Tenant's own internal reference / circuit label
    internal_circuit_id TEXT,

    -- Previous carrier circuit ID if the circuit was re-identified during
    -- a carrier migration / re-grooming without physical change
    legacy_circuit_id   TEXT,

    -- -------------------------------------------------------------------------
    -- Service classification
    -- -------------------------------------------------------------------------
    circuit_type        circuit_type        NOT NULL,
    circuit_media       circuit_media       NOT NULL,
    handoff_interface   handoff_interface   NOT NULL,
    handoff_connector   handoff_connector,              -- NULL for copper / coax circuits
    status              circuit_status      NOT NULL DEFAULT 'ordering',

    -- -------------------------------------------------------------------------
    -- Bandwidth
    -- -------------------------------------------------------------------------
    -- Access port / physical speed
    port_speed_mbps     INTEGER             NOT NULL CHECK (port_speed_mbps > 0),

    -- Committed Information Rate (equals port_speed for DIA; may be lower for
    -- burstable or shared services such as GPON or cable)
    cir_mbps            INTEGER             NOT NULL CHECK (cir_mbps > 0),

    -- Burst / peak rate above CIR (NULL = no burst, service is non-burstable)
    burst_mbps          INTEGER                      CHECK (burst_mbps > 0),

    -- -------------------------------------------------------------------------
    -- Physical demarcation
    -- -------------------------------------------------------------------------
    -- Where in the building the circuit terminates (MDF room, IDF, comms closet)
    demarc_location     TEXT,

    -- Rack / cabinet identifier at the demarc (e.g. "RACK-MDF-01")
    demarc_rack         TEXT,

    -- Patch panel / termination block (e.g. "PP-01")
    demarc_panel        TEXT,

    -- Port on the panel (e.g. "Port 12")
    demarc_port         TEXT,

    -- VLAN tagging at the handoff (NULL = untagged; 0 = native; 1–4094 = tagged)
    handoff_vlan_id     SMALLINT            CHECK (handoff_vlan_id BETWEEN 0 AND 4094),

    -- -------------------------------------------------------------------------
    -- Redundancy
    -- -------------------------------------------------------------------------
    -- Self-referential: backup circuits point to their primary
    primary_circuit_id  BIGINT,             -- NULL = this is the primary (or standalone)
    is_diverse_path     BOOLEAN NOT NULL DEFAULT FALSE,
                        -- TRUE = confirmed diverse physical route from primary

    -- -------------------------------------------------------------------------
    -- SLA — contract-specific values; override carrier defaults
    -- -------------------------------------------------------------------------
    sla_uptime_percent  NUMERIC(6,4)        CHECK (sla_uptime_percent BETWEEN 0 AND 100),
    sla_mttr_hours      NUMERIC(5,2)        CHECK (sla_mttr_hours > 0),
    sla_install_days    SMALLINT            CHECK (sla_install_days > 0),

    -- -------------------------------------------------------------------------
    -- Contract / commercial
    -- -------------------------------------------------------------------------
    contract_start_date DATE,
    contract_end_date   DATE,               -- NULL = month-to-month / evergreen
    contract_term_months SMALLINT           CHECK (contract_term_months > 0),

    -- Monthly Recurring Cost (MRC) and Non-Recurring Cost (NRC / install fee)
    mrc                 NUMERIC(12,2)       CHECK (mrc >= 0),
    nrc                 NUMERIC(12,2)       CHECK (nrc >= 0),
    currency            TEXT    NOT NULL DEFAULT 'USD',  -- ISO 4217

    -- Purchase order or billing reference the tenant uses for this circuit
    purchase_order_ref  TEXT,

    -- -------------------------------------------------------------------------
    -- Operational
    -- -------------------------------------------------------------------------
    installed_at        TIMESTAMPTZ,        -- date circuit went live
    last_outage_at      TIMESTAMPTZ,        -- most recent outage start (informational)

    -- Human-readable carrier maintenance window, e.g. "Sun 02:00–06:00 ET"
    maintenance_window  TEXT,

    -- Active carrier trouble-ticket number (cleared when resolved)
    active_ticket_ref   TEXT,

    notes               TEXT,

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ,

    CONSTRAINT uq_data_circuits_uuid UNIQUE (uuid),

    CONSTRAINT chk_data_circuits_cir_le_port   CHECK (cir_mbps <= port_speed_mbps),
    CONSTRAINT chk_data_circuits_burst_ge_cir  CHECK (burst_mbps IS NULL OR burst_mbps >= cir_mbps),
    CONSTRAINT chk_data_circuits_contract_dates CHECK (
        contract_end_date IS NULL OR contract_end_date > contract_start_date
    ),
    CONSTRAINT chk_data_circuits_currency_len   CHECK (char_length(currency) = 3),

    CONSTRAINT fk_data_circuits_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_data_circuits_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_data_circuits_carrier
        FOREIGN KEY (carrier_id)
        REFERENCES carriers (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_data_circuits_carrier_account
        FOREIGN KEY (carrier_account_id)
        REFERENCES carrier_accounts (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_data_circuits_primary_circuit
        FOREIGN KEY (primary_circuit_id)
        REFERENCES data_circuits (id)
        ON DELETE SET NULL
);

-- Carrier circuit IDs are unique per carrier (not across carriers)
CREATE UNIQUE INDEX uq_data_circuits_carrier_circuit_id
    ON data_circuits (carrier_id, carrier_circuit_id)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_data_circuits_tenant_id          ON data_circuits (tenant_id);
CREATE INDEX idx_data_circuits_property_id        ON data_circuits (property_id);
CREATE INDEX idx_data_circuits_carrier_id         ON data_circuits (carrier_id);
CREATE INDEX idx_data_circuits_carrier_account_id ON data_circuits (carrier_account_id);
CREATE INDEX idx_data_circuits_status             ON data_circuits (status);
CREATE INDEX idx_data_circuits_circuit_type       ON data_circuits (circuit_type);
CREATE INDEX idx_data_circuits_primary_circuit_id ON data_circuits (primary_circuit_id);
CREATE INDEX idx_data_circuits_contract_end_date  ON data_circuits (contract_end_date)
    WHERE contract_end_date IS NOT NULL;  -- supports contract-expiry reporting
CREATE INDEX idx_data_circuits_deleted_at         ON data_circuits (deleted_at);

CREATE TRIGGER trg_data_circuits_set_updated_at
    BEFORE UPDATE ON data_circuits
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
