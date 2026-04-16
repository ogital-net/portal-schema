-- =============================================================================
-- V1: Initial Schema
--
-- Tables (in dependency order):
--   tenants                 — top-level SaaS tenant (service provider / ISP)
--   platform_config         — per-tenant branding and platform configuration
--   organizations           — service provider sub-entities / brands under a tenant
--   property_management_companies — companies responsible for day-to-day property management
--   properties              — physical buildings / complexes
--   property_contacts       — individual contacts per property displayed to residents
--   buildings               — individual structures within a property
--   units                   — individual rentable spaces
--   manufacturers           — hardware vendor registry
--   ap_groups               — WiFi configuration profiles (SSID, security, VLAN)
--   network_devices         — all managed network equipment at a property
--   access_points           — AP-specific detail (1:1 with network_devices)
--   switches                — switch-specific detail (1:1 with network_devices)
--   gateways                — gateway-specific detail (1:1 with network_devices)
--   gateway_interfaces      — per-interface config and IP addressing for a gateway
--   unit_networks           — per-unit L2 + DHCP config, linked to IPAM prefixes
--   device_credentials      — encrypted management credentials per device
--   service_plans           — available network service tiers
--   service_accounts        — contracted service period for a unit
--   users                   — human user accounts (Cognito-backed)
--   user_units              — M:M: users ↔ units
--   service_account_users   — M:M: users ↔ service accounts
--   guest_users             — transient visitors, contractors, prospective residents
--   carriers                — carrier/telco companies, tenant-scoped
--   carrier_contacts        — escalation contact directory per carrier
--   carrier_accounts        — billing/MSA account a tenant holds with a carrier
--   data_circuits           — individual access circuit at a property
--   vrfs                    — virtual routing and forwarding instances
--   ip_prefixes             — hierarchical prefix registry (RIR → market → property → subscriber)
--   ip_addresses            — individual host address assignments to gateway interfaces
--   prefix_assignments      — prefix delegations and block allocations to units
--   pollers                 — distributed SNMP polling agents
--   (poller_id on network_devices links each device to its assigned poller)
--   (poller_interface_ref on gateway_interfaces stores the per-interface opaque ID)
--
-- Support Ticketing:
--   ticket_category_types   — extensible type registry; system defaults + per-tenant additions
--   ticket_categories       — two-level category taxonomy (parent / child)
--   support_tickets         — per-property tickets, optionally linked to a unit
--   ticket_comments         — threaded comment / activity log per ticket
--   ticket_attachments      — files attached to a ticket or a comment
--   ticket_watchers         — users subscribed to ticket notifications
--
-- Physical Infrastructure:
--   unit_ethernet_jacks     — per-room ethernet wall drops within a unit
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS citext;

-- ---------------------------------------------------------------------------
-- Utility Functions
-- ---------------------------------------------------------------------------

-- Note: uuidv7() is a built-in function in PostgreSQL 18+; no custom
-- implementation needed.

-- Automatically bump updated_at on every UPDATE
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- tenants
-- The top-level SaaS entity.  Each tenant is a service provider / ISP that
-- signs up to use the platform.  Every other table is scoped to a tenant.
-- ---------------------------------------------------------------------------
CREATE TABLE tenants (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),

    -- Identity
    name        TEXT        NOT NULL,
    slug        TEXT        NOT NULL,   -- URL-safe subdomain identifier, e.g. "acme-isp"

    -- Contact
    phone       TEXT,
    email       CITEXT,
    website     TEXT,

    -- Account state
    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_tenants_uuid UNIQUE (uuid),
    CONSTRAINT uq_tenants_name UNIQUE (name),
    CONSTRAINT uq_tenants_slug UNIQUE (slug),
    CONSTRAINT chk_tenants_slug_format CHECK (slug ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$')
);

CREATE INDEX idx_tenants_slug       ON tenants (slug);
CREATE INDEX idx_tenants_is_active  ON tenants (is_active);
CREATE INDEX idx_tenants_deleted_at ON tenants (deleted_at);

CREATE TRIGGER trg_tenants_set_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- platform_config
-- Per-tenant portal branding and configuration.  1:1 with tenants.
-- A row is created for the tenant at sign-up and is always present;
-- use NULL fields to indicate "use platform default".
-- ---------------------------------------------------------------------------
CREATE TABLE platform_config (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,

    -- Branding — displayed in the portal UI
    platform_name   TEXT,           -- override for the product name shown in the UI
    logo_url        TEXT,           -- primary (light background) logo
    logo_dark_url   TEXT,           -- dark-mode / inverted logo variant
    favicon_url     TEXT,

    -- Color palette (CSS hex values, e.g. '#1a73e8')
    color_primary   TEXT,
    color_secondary TEXT,
    color_accent    TEXT,

    -- Support contact shown to residents
    support_email   CITEXT,
    support_phone   TEXT,
    support_url     TEXT,

    -- Legal
    terms_url       TEXT,
    privacy_url     TEXT,

    -- Catch-all for additional configuration not yet promoted to a typed column.
    -- Application-defined keys; validated by the backend.
    extra_config    JSONB       NOT NULL DEFAULT '{}',

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_platform_config_uuid      UNIQUE (uuid),
    CONSTRAINT uq_platform_config_tenant_id UNIQUE (tenant_id),   -- 1:1 with tenants

    CONSTRAINT fk_platform_config_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE CASCADE
);

CREATE INDEX idx_platform_config_tenant_id ON platform_config (tenant_id);

CREATE TRIGGER trg_platform_config_set_updated_at
    BEFORE UPDATE ON platform_config
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- Enum Types
-- ---------------------------------------------------------------------------

CREATE TYPE property_type AS ENUM (
    'apartment_complex',  -- traditional multi-unit residential complex
    'mixed_use',          -- combined commercial + residential
    'student_housing',    -- student-targeted housing
    'senior_living',      -- 55+ / assisted-living community
    'affordable_housing', -- subsidized / income-restricted housing
    'condo_building',     -- condominium building
    'townhome_community', -- townhome / row-home development
    'single_building'     -- standalone single-building property
);

-- How network access is delivered to residents at the property
CREATE TYPE property_network_service_type AS ENUM (
    'wifi_only',              -- residents receive WiFi; no wired Ethernet drop to unit
    'wired_only',             -- Ethernet jack to unit only; no managed WiFi
    'wired_and_wifi',         -- both Ethernet drop and managed WiFi provided
    'mdu_bulk_wifi',          -- bulk/managed WiFi billed through property, not resident
    'fiber_to_unit',          -- dedicated fiber termination inside each unit
    'hybrid'                  -- mix of delivery types across unit classes on the property
);

-- IEEE 802.11 WiFi generation used for resident-facing APs
CREATE TYPE property_wifi_generation AS ENUM (
    'wifi_4',   -- 802.11n
    'wifi_5',   -- 802.11ac
    'wifi_6',   -- 802.11ax (2.4 / 5 GHz)
    'wifi_6e',  -- 802.11ax + 6 GHz band
    'wifi_7',   -- 802.11be (multi-link operation)
    'wifi_8'    -- 802.11bn (anticipated next generation)
);

CREATE TYPE unit_type AS ENUM (
    'studio',
    'one_bedroom',
    'two_bedroom',
    'three_bedroom',
    'four_plus_bedroom',
    'loft',
    'penthouse',
    'commercial'          -- for ground-floor retail in mixed-use buildings
);

CREATE TYPE device_type AS ENUM (
    'access_point',
    'switch',
    'router',
    'onu',           -- optical network unit (fiber demarcation)
    'gateway',
    'other'
);

CREATE TYPE device_status AS ENUM (
    'provisioning',  -- registered but not yet online
    'online',
    'offline',
    'maintenance',   -- taken out of service temporarily
    'decommissioned' -- permanently retired
);

-- device_location_type enum removed; replaced by the device_location_types lookup
-- table below, which supports per-tenant customization.

CREATE TYPE wifi_security AS ENUM (
    'open',
    'wpa2_personal',
    'wpa3_personal',
    'wpa2_enterprise',
    'wpa3_enterprise',
    'wpa2_wpa3_personal'   -- transition mode
);

-- Three-tier campus model; most MDFs are core/distribution, IDFs are access.
CREATE TYPE switch_role AS ENUM (
    'core',         -- aggregates all distribution/uplinks; typically in MDF
    'distribution', -- aggregates access switches for a building or floor
    'access'        -- edge switches: directly connects APs, VoIP, workstations
);

CREATE TYPE ipv6_mode AS ENUM (
    'disabled',
    'static',       -- manually assigned prefix + gateway
    'slaac',        -- stateless address autoconfiguration (RFC 4862)
    'dhcpv6',       -- stateful DHCPv6 (RFC 3315)
    'slaac_dhcpv6'  -- SLAAC for address, DHCPv6 for options (most common dual-stack)
);

-- Physical / logical layer of a gateway interface
CREATE TYPE interface_type AS ENUM (
    'ethernet',  -- physical Ethernet port (e.g. eth0, sfp0)
    'vlan',      -- 802.1Q VLAN sub-interface (e.g. eth0.100)
    'tunnel',    -- encapsulated tunnel: GRE, IPIP, WireGuard, L2TP, etc.
    'bridge',    -- software bridge (aggregates multiple ports/VLANs)
    'lag'        -- link aggregation group / LACP bond
);

-- Functional role of a gateway interface within the network architecture
CREATE TYPE interface_role AS ENUM (
    'wan',            -- upstream ISP handoff; carries public/transit addressing
    'subscriber',     -- serves one or more residential units (per-unit VLANs)
    'management',     -- in-band or out-of-band device management plane
    'infrastructure', -- internal backbone: NOC monitoring, common-area, shared services
    'guest',          -- guest / visitor WiFi uplink
    'iot',            -- isolated IoT / smart-home VLAN
    'other'
);

CREATE TYPE credential_type AS ENUM (
    'ssh_password',     -- username + password over SSH
    'ssh_key',          -- username + private key over SSH
    'snmp_v2c',         -- community string
    'snmp_v3',          -- authProtocol + privProtocol + passphrases
    'http_basic',       -- username + password over HTTP
    'https_basic',      -- username + password over HTTPS
    'api_key',          -- bearer / X-API-Key token
    'radius',           -- RADIUS shared secret
    'tacacs_plus'       -- TACACS+ shared secret
);

CREATE TYPE building_construction_type AS ENUM (
    'wrap',          -- wood-frame units wrap around a concrete podium parking structure
    'greenfield',    -- new ground-up construction on a previously undeveloped site
    'garden',        -- low-rise garden-style complex; exterior corridor access, landscaped courtyards
    'mid_rise',      -- 5–12 story building; typically wood or concrete construction
    'high_rise',     -- 13+ story building; steel or reinforced concrete
    'townhouse',     -- attached multi-floor units with individual ground-level entrances
    'mixed_use',     -- residential over ground-floor retail / commercial
    'other'
);

-- Physical-layer distribution technology used to deliver connectivity inside
-- the building from the MDF/head-end to individual units or floors.
CREATE TYPE building_distribution_tech AS ENUM (
    -- Active Ethernet (point-to-point switched Ethernet runs to each unit)
    'active_ethernet_copper',   -- Cat5e/Cat6/Cat6A copper to each unit
    'active_ethernet_fiber',    -- dedicated single-mode or multimode fiber to each unit

    -- Passive Optical Network (shared fiber, PON splitter in riser/IDF)
    'gpon',                     -- ITU-T G.984 GPON — up to 2.5 Gbps down / 1.25 Gbps up shared
    'xgs_pon',                  -- ITU-T G.9807 XGS-PON — 10 Gbps symmetric shared
    'ng_pon2',                  -- ITU-T G.989 NG-PON2 — 40 Gbps (4×10G wavelengths)
    'epon',                     -- IEEE 802.3ah EPON — 1 Gbps shared (less common in MDU)
    '10g_epon',                 -- IEEE 802.3av 10G-EPON — 10 Gbps shared

    -- Copper-based broadband (existing telephone or coax wiring reused)
    'vdsl2',                    -- VDSL2 (G.993.2) over existing telephone copper
    'vdsl2_vectoring',          -- VDSL2 with G.993.5 vectoring / crosstalk cancellation
    'gfast',                    -- G.fast (G.9700/G.9701) — up to 1 Gbps over short copper
    'adsl2_plus',               -- ADSL2+ legacy DSL (older MDU installs)

    -- G.hn — ITU-T G.9960/G.9961 home networking over existing building wiring
    'ghn_coax',                 -- G.hn over existing coaxial cable
    'ghn_copper',               -- G.hn over existing telephone-grade copper pairs
    'ghn_powerline',            -- G.hn over in-building power line (less common in MDU)

    -- Cable / DOCSIS (coaxial HFC plant)
    'docsis_3_0',               -- DOCSIS 3.0 — up to 1 Gbps down shared
    'docsis_3_1',               -- DOCSIS 3.1 — up to 10 Gbps down shared
    'docsis_4_0',               -- DOCSIS 4.0 — 10 Gbps full-duplex

    -- Wireless distribution inside building
    'moca',                     -- MoCA over existing coax (point-to-point, set-top/gateway backhauling)
    'wimax',                    -- 802.16 WiMAX fixed wireless (uncommon, legacy)

    -- Hybrid / multi-technology
    'hybrid_fiber_copper',      -- fiber to IDF then copper to unit (e.g. VDSL2 from IDF)
    'hybrid_fiber_coax',        -- fiber to node then DOCSIS coax to unit (HFC)
    'hybrid_fiber_ghn',         -- fiber to IDF then G.hn over existing wiring to unit

    'other'                     -- proprietary or unlisted technology
);

-- ---------------------------------------------------------------------------
-- organizations
-- A service-provider sub-entity or brand under a tenant.  One tenant may
-- have one or more organizations (e.g. parent ISP with regional brands).
-- ---------------------------------------------------------------------------
CREATE TABLE organizations (
    id           BIGSERIAL    PRIMARY KEY,
    uuid         UUID         NOT NULL DEFAULT uuidv7(),
    tenant_id    BIGINT       NOT NULL,

    -- Identity
    name         CITEXT       NOT NULL,
    phone        TEXT,
    email        CITEXT,
    website      TEXT,

    -- Mailing / registered address
    address_line1 TEXT        NOT NULL,
    address_line2 TEXT,
    city          TEXT        NOT NULL,
    state         TEXT        NOT NULL,
    postal_code   TEXT        NOT NULL,
    country       TEXT        NOT NULL DEFAULT 'US',

    -- Timestamps
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ,

    CONSTRAINT uq_organizations_uuid       UNIQUE (uuid),
    CONSTRAINT uq_organizations_tenant_name UNIQUE (tenant_id, name),
    CONSTRAINT chk_organizations_country_len CHECK (char_length(country) = 2),

    CONSTRAINT fk_organizations_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_organizations_tenant_id  ON organizations (tenant_id);
CREATE INDEX idx_organizations_deleted_at ON organizations (deleted_at);

CREATE TRIGGER trg_organizations_set_updated_at
    BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- property_management_companies
-- A company (or individual operator) engaged to handle day-to-day operations
-- for one or more properties owned by an organization.  The organization is
-- the asset owner / ISP account; the management company may be the owner's
-- own internal team or a third-party property-management firm.
--
-- Scoped to an organization: a management company record belongs to exactly
-- one organization and is not shared across organizations.
-- ---------------------------------------------------------------------------
CREATE TABLE property_management_companies (
    id              BIGSERIAL   PRIMARY KEY,
    uuid            UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT      NOT NULL,
    organization_id BIGINT      NOT NULL,  -- the organization that engaged this management company

    -- Identity
    name        TEXT        NOT NULL,
    website     TEXT,

    -- Primary contact info (company-level; individual contacts go in property_contacts)
    phone       TEXT,           -- main office line
    fax         TEXT,
    email       CITEXT,         -- general inbox, e.g. info@acmeproperty.com

    -- Mailing / registered office address
    address_line1   TEXT,
    address_line2   TEXT,
    city            TEXT,
    state           TEXT,
    postal_code     TEXT,
    country         TEXT        NOT NULL DEFAULT 'US',

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_property_management_companies_uuid
        UNIQUE (uuid),

    CONSTRAINT chk_property_management_companies_country_len
        CHECK (char_length(country) = 2),

    -- Address is either fully present or fully absent
    CONSTRAINT chk_property_management_companies_address_complete
        CHECK (
            (address_line1 IS NULL AND city IS NULL AND state IS NULL AND
             postal_code IS NULL)
            OR
            (address_line1 IS NOT NULL AND city IS NOT NULL AND state IS NOT NULL AND
             postal_code IS NOT NULL)
        ),

    CONSTRAINT fk_property_management_companies_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_property_management_companies_organization
        FOREIGN KEY (organization_id)
        REFERENCES organizations (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_property_management_companies_tenant_id
    ON property_management_companies (tenant_id);
CREATE INDEX idx_property_management_companies_organization_id
    ON property_management_companies (organization_id);
CREATE INDEX idx_property_management_companies_deleted_at
    ON property_management_companies (deleted_at);

CREATE TRIGGER trg_property_management_companies_set_updated_at
    BEFORE UPDATE ON property_management_companies
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- properties
-- A physical property (building, complex, campus) managed by an organization.
-- One organization may own many properties.
-- ---------------------------------------------------------------------------
CREATE TABLE properties (
    id              BIGSERIAL       PRIMARY KEY,
    uuid            UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT          NOT NULL,
    organization_id BIGINT          NOT NULL,
    management_company_id BIGINT,   -- NULL until assigned; links to property_management_companies

    -- Identity
    name            TEXT            NOT NULL,
    property_type   property_type   NOT NULL DEFAULT 'apartment_complex',

    -- Physical address
    address_line1   TEXT            NOT NULL,
    address_line2   TEXT,
    city            TEXT            NOT NULL,
    state           TEXT            NOT NULL,
    postal_code     TEXT            NOT NULL,
    country         TEXT            NOT NULL DEFAULT 'US',

    -- Geolocation (WGS-84 decimal degrees; nullable until geocoded)
    latitude        DOUBLE PRECISION,
    longitude       DOUBLE PRECISION,

    -- Physical attributes
    year_built      SMALLINT,
    total_floors    SMALLINT,       -- floors across the entire property
    unit_count      INTEGER,        -- advertised / expected unit count (not enforced)

    -- Network service delivery
    network_service_type    property_network_service_type,
                            -- how connectivity is delivered to residents; NULL = not yet configured
    wifi_generation         property_wifi_generation,
                            -- WiFi generation of resident-facing APs; NULL if wired_only or not yet deployed
    has_guest_wifi          BOOLEAN NOT NULL DEFAULT FALSE,
                            -- property offers a separate guest / visitor SSID
    has_iot_network         BOOLEAN NOT NULL DEFAULT FALSE,
                            -- dedicated IoT VLAN / SSID for smart-home devices
    has_bulk_tv             BOOLEAN NOT NULL DEFAULT FALSE,
                            -- bulk cable/IPTV included in property agreement
    has_voip                BOOLEAN NOT NULL DEFAULT FALSE,
                            -- VoIP / managed phone service included
    uplink_redundancy       BOOLEAN NOT NULL DEFAULT FALSE,
                            -- TRUE = at least two diverse WAN circuits (failover / load-balance)

    -- Operational
    timezone        TEXT            NOT NULL DEFAULT 'America/New_York',
                                    -- IANA tz; used for scheduled maintenance windows etc.
    notes           TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_properties_uuid UNIQUE (uuid),
    CONSTRAINT chk_properties_country_len  CHECK (char_length(country) = 2),
    CONSTRAINT chk_properties_latitude     CHECK (latitude  BETWEEN -90  AND  90),
    CONSTRAINT chk_properties_longitude    CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT chk_properties_year_built   CHECK (year_built BETWEEN 1800 AND 2200),
    CONSTRAINT chk_properties_total_floors CHECK (total_floors > 0),
    CONSTRAINT chk_properties_unit_count   CHECK (unit_count > 0),

    CONSTRAINT fk_properties_organization
        FOREIGN KEY (organization_id)
        REFERENCES organizations (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_properties_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_properties_management_company
        FOREIGN KEY (management_company_id)
        REFERENCES property_management_companies (id)
        ON DELETE SET NULL
);

CREATE INDEX idx_properties_tenant_id            ON properties (tenant_id);
CREATE INDEX idx_properties_organization_id      ON properties (organization_id);
CREATE INDEX idx_properties_management_company_id ON properties (management_company_id)
    WHERE management_company_id IS NOT NULL;
CREATE INDEX idx_properties_deleted_at           ON properties (deleted_at);

-- Spatial lookup: find all properties within a bounding box
CREATE INDEX idx_properties_geo ON properties (latitude, longitude)
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

CREATE TRIGGER trg_properties_set_updated_at
    BEFORE UPDATE ON properties
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- property_contact_role enum
-- ---------------------------------------------------------------------------
CREATE TYPE property_contact_role AS ENUM (
    'property_manager',  -- primary day-to-day manager; main point of contact
    'assistant_manager', -- secondary manager / backup contact
    'leasing',           -- leasing office: move-ins, move-outs, applications
    'maintenance',       -- maintenance requests and repair coordination
    'emergency',         -- after-hours emergency line (could be a service, not a person)
    'billing',           -- rent payments, billing disputes, fee questions
    'concierge',         -- front-desk / doorman service (for luxury/high-rise)
    'general'            -- general inquiries not covered by other roles
);

-- ---------------------------------------------------------------------------
-- property_contacts
-- Individual contacts (people or role-based lines) associated with a property.
-- Multiple contacts per property are supported; mark one per role as primary.
-- These records are displayed to residents in the portal.
-- ---------------------------------------------------------------------------
CREATE TABLE property_contacts (
    id                      BIGSERIAL               PRIMARY KEY,
    uuid                    UUID                    NOT NULL DEFAULT uuidv7(),
    tenant_id               BIGINT                  NOT NULL,
    property_id             BIGINT                  NOT NULL,

    -- Optionally link to the management company this person works for
    management_company_id   BIGINT,

    -- Role this contact fills at the property
    role                    property_contact_role   NOT NULL DEFAULT 'general',

    -- Flag the primary contact for each role (used for default display ordering)
    is_primary              BOOLEAN                 NOT NULL DEFAULT FALSE,

    -- Person identity (nullable: emergency lines may have no named individual)
    first_name              TEXT,
    last_name               TEXT,
    title                   TEXT,   -- e.g. "Property Manager", "Leasing Director"

    -- Contact channels
    phone                   TEXT,           -- primary phone / office line
    phone_ext               TEXT,           -- extension for office PBX systems
    phone_after_hours       TEXT,           -- emergency / after-hours line
    email                   CITEXT,         -- contact email shown to residents
    email_secondary         CITEXT,         -- secondary or department-level email

    -- Availability note shown to residents (free-form)
    -- e.g. "Mon–Fri 9 am–5 pm EST", "24/7 answering service"
    office_hours            TEXT,

    -- Portal display
    display_name            TEXT,           -- override shown in portal if set;
                                            -- falls back to first_name + last_name
    profile_photo_url       TEXT,           -- optional headshot for display
    is_visible_to_residents BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Internal notes (not shown to residents)
    notes                   TEXT,

    -- Sort order within a role group (lower = shown first)
    sort_order              SMALLINT        NOT NULL DEFAULT 0,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_property_contacts_uuid UNIQUE (uuid),

    CONSTRAINT fk_property_contacts_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_property_contacts_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_property_contacts_management_company
        FOREIGN KEY (management_company_id)
        REFERENCES property_management_companies (id)
        ON DELETE SET NULL
);

CREATE INDEX idx_property_contacts_property_id
    ON property_contacts (property_id);
CREATE INDEX idx_property_contacts_tenant_id
    ON property_contacts (tenant_id);
CREATE INDEX idx_property_contacts_management_company_id
    ON property_contacts (management_company_id)
    WHERE management_company_id IS NOT NULL;
CREATE INDEX idx_property_contacts_deleted_at
    ON property_contacts (deleted_at);

-- Partial index to quickly fetch visible contacts for resident portal queries
CREATE INDEX idx_property_contacts_visible
    ON property_contacts (property_id, role, sort_order)
    WHERE is_visible_to_residents = TRUE AND deleted_at IS NULL;

CREATE TRIGGER trg_property_contacts_set_updated_at
    BEFORE UPDATE ON property_contacts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- buildings
-- An individual structure within a property.  A simple single-building
-- community may have no rows here; large complexes will have one per tower
-- or wing (e.g. "Building A", "North Tower", "Phase 2").
-- ---------------------------------------------------------------------------
CREATE TABLE buildings (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    property_id BIGINT      NOT NULL,

    -- Identity
    name        TEXT        NOT NULL, -- "Building A", "Tower 1", "North Wing"
    code        TEXT,                 -- short internal code, e.g. "A", "N1"

    -- Street address (overrides property address when the building has its own
    -- entrance / address; leave NULL to inherit from the parent property)
    address_line1 TEXT,
    address_line2 TEXT,
    city          TEXT,
    state         TEXT,
    postal_code   TEXT,
    country       TEXT,

    -- Physical attributes
    year_built          SMALLINT,
    total_floors        SMALLINT,
    construction_type   building_construction_type,
    distribution_tech   building_distribution_tech,
                        -- physical-layer technology delivering connectivity to units

    -- Accessibility
    has_elevator    BOOLEAN     NOT NULL DEFAULT FALSE,
    is_accessible   BOOLEAN     NOT NULL DEFAULT FALSE, -- ADA / full wheelchair access

    notes           TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_buildings_uuid              UNIQUE (uuid),
    CONSTRAINT uq_buildings_property_code     UNIQUE (property_id, code),
    CONSTRAINT chk_buildings_country_len      CHECK (country IS NULL OR char_length(country) = 2),
    CONSTRAINT chk_buildings_year_built       CHECK (year_built BETWEEN 1800 AND 2200),
    CONSTRAINT chk_buildings_total_floors     CHECK (total_floors > 0),
    CONSTRAINT chk_buildings_address_complete CHECK (
        (address_line1 IS NULL AND city IS NULL AND state IS NULL AND
         postal_code IS NULL AND country IS NULL)
        OR
        (address_line1 IS NOT NULL AND city IS NOT NULL AND state IS NOT NULL AND
         postal_code IS NOT NULL AND country IS NOT NULL)
    ),

    CONSTRAINT fk_buildings_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_buildings_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_buildings_tenant_id   ON buildings (tenant_id);
CREATE INDEX idx_buildings_property_id ON buildings (property_id);
CREATE INDEX idx_buildings_deleted_at  ON buildings (deleted_at);

CREATE TRIGGER trg_buildings_set_updated_at
    BEFORE UPDATE ON buildings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- units
-- An individual rentable / occupiable space within a property.
-- May be inside a specific building, or attached directly to the property
-- when the property has no distinct buildings.
-- ---------------------------------------------------------------------------
CREATE TABLE units (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    property_id BIGINT      NOT NULL,
    building_id BIGINT,     -- NULL → unit belongs directly to the property

    -- Identity
    unit_number TEXT        NOT NULL, -- "101", "B-204", "PH-3", "Ground Retail"
    floor       SMALLINT,             -- floor level; 0 = ground, negative = below grade
    floor_count SMALLINT NOT NULL DEFAULT 1 CHECK (floor_count >= 1),
                        -- number of floors this unit spans (e.g. 2 for a townhouse/maisonette)

    -- Classification
    unit_type   unit_type   NOT NULL DEFAULT 'one_bedroom',
    bedrooms    SMALLINT    NOT NULL DEFAULT 1 CHECK (bedrooms >= 0),
    bathrooms   NUMERIC(3,1) NOT NULL DEFAULT 1.0 CHECK (bathrooms > 0),
    square_feet NUMERIC(8,2) CHECK (square_feet > 0),

    -- Features
    is_accessible   BOOLEAN NOT NULL DEFAULT FALSE, -- ADA / wheelchair accessible unit
    has_balcony     BOOLEAN NOT NULL DEFAULT FALSE,
    has_in_unit_laundry BOOLEAN NOT NULL DEFAULT FALSE,
    has_parking     BOOLEAN NOT NULL DEFAULT FALSE,
    parking_spaces  SMALLINT NOT NULL DEFAULT 0 CHECK (parking_spaces >= 0),

    notes       TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_units_uuid UNIQUE (uuid),

    CONSTRAINT fk_units_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_units_building
        FOREIGN KEY (building_id)
        REFERENCES buildings (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_units_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

-- Prevent duplicate unit numbers within the same building
CREATE UNIQUE INDEX uq_units_building_unit_number
    ON units (building_id, unit_number)
    WHERE building_id IS NOT NULL AND deleted_at IS NULL;

-- Prevent duplicate unit numbers on property when not tied to a building
CREATE UNIQUE INDEX uq_units_property_unit_number_no_building
    ON units (property_id, unit_number)
    WHERE building_id IS NULL AND deleted_at IS NULL;

CREATE INDEX idx_units_tenant_id    ON units (tenant_id);
CREATE INDEX idx_units_property_id  ON units (property_id);
CREATE INDEX idx_units_building_id  ON units (building_id);
CREATE INDEX idx_units_unit_type    ON units (unit_type);
CREATE INDEX idx_units_deleted_at   ON units (deleted_at);

CREATE TRIGGER trg_units_set_updated_at
    BEFORE UPDATE ON units
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- manufacturers
-- Canonical registry of hardware vendors.  Referenced by network_devices.
-- Serial numbers are only unique within a manufacturer's namespace.
-- ---------------------------------------------------------------------------
CREATE TABLE manufacturers (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,

    -- Identity
    name        TEXT        NOT NULL,   -- e.g. "Ubiquiti", "Cisco", "Aruba"
    short_name  TEXT,                   -- abbreviation used in labels/UI, e.g. "UBNT"

    -- Vendor contact / support
    support_url     TEXT,
    support_phone   TEXT,
    support_email   CITEXT,
    portal_url      TEXT,               -- vendor management portal URL

    -- RMA / warranty reference
    warranty_portal_url TEXT,

    notes       TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_manufacturers_uuid             UNIQUE (uuid),
    CONSTRAINT uq_manufacturers_tenant_name       UNIQUE (tenant_id, name),
    CONSTRAINT uq_manufacturers_tenant_short_name UNIQUE (tenant_id, short_name),

    CONSTRAINT fk_manufacturers_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_manufacturers_tenant_id  ON manufacturers (tenant_id);
CREATE INDEX idx_manufacturers_deleted_at ON manufacturers (deleted_at);

CREATE TRIGGER trg_manufacturers_set_updated_at
    BEFORE UPDATE ON manufacturers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ap_groups
-- A named configuration profile applied to one or more access points.
-- Represents concepts like "Unit WiFi", "Common Area Guest", "IoT VLAN".
-- All APs in the same group share the same SSID, security mode, and VLAN.
-- ---------------------------------------------------------------------------
CREATE TABLE ap_groups (
    id          BIGSERIAL       PRIMARY KEY,
    uuid        UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT          NOT NULL,
    property_id BIGINT          NOT NULL,

    -- Identity
    name        TEXT            NOT NULL,  -- e.g. "Resident WiFi", "Guest", "IoT"

    -- Wireless configuration
    ssid            TEXT        NOT NULL,
    ssid_hidden     BOOLEAN     NOT NULL DEFAULT FALSE,
    security        wifi_security NOT NULL DEFAULT 'wpa3_personal',

    -- Network segmentation
    vlan_id         SMALLINT,   -- NULL = untagged / native VLAN
                                -- valid 802.1Q range enforced below
    -- Radio policy
    band_steering_enabled BOOLEAN NOT NULL DEFAULT TRUE,
                    -- steer dual-band clients to 5 GHz / 6 GHz when possible
    fast_roaming_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
                    -- 802.11r/k/v for seamless AP-to-AP handoff within group

    notes           TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_ap_groups_uuid          UNIQUE (uuid),
    CONSTRAINT uq_ap_groups_property_name UNIQUE (property_id, name),
    CONSTRAINT chk_ap_groups_vlan_range   CHECK (vlan_id BETWEEN 1 AND 4094),

    CONSTRAINT fk_ap_groups_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ap_groups_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_ap_groups_tenant_id   ON ap_groups (tenant_id);
CREATE INDEX idx_ap_groups_property_id ON ap_groups (property_id);
CREATE INDEX idx_ap_groups_deleted_at  ON ap_groups (deleted_at);

CREATE TRIGGER trg_ap_groups_set_updated_at
    BEFORE UPDATE ON ap_groups
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- device_location_types
-- Lookup table for the coarse physical location category of a network device.
-- Detailed free-text goes in network_devices.location_description.
--
-- Rows with tenant_id IS NULL are platform-wide defaults visible to every
-- tenant.  Rows with tenant_id set are private to that tenant, allowing them
-- to add custom location categories without touching the global list.
--
-- Global default rows are seeded by the INSERT block below.  Tenants may
-- mark global rows as hidden by creating a tenant-scoped row with the same
-- slug and is_active = FALSE (application-layer convention; not enforced
-- by the DB).  The slug is the stable machine-readable key; label is the
-- human-facing display string.
-- ---------------------------------------------------------------------------
CREATE TABLE device_location_types (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),

    -- NULL = global platform default; NOT NULL = tenant-specific custom type
    tenant_id   BIGINT,

    slug        TEXT        NOT NULL,   -- stable machine key, e.g. 'mdf', 'unit'
    label       TEXT        NOT NULL,   -- display name, e.g. 'MDF / Telecom Closet'
    description TEXT,                   -- optional longer description for UI tooltips
    sort_order  SMALLINT    NOT NULL DEFAULT 0,
                            -- controls display ordering within a category list
    is_external BOOLEAN     NOT NULL DEFAULT FALSE,
                            -- TRUE = location is outside the building envelope (outdoor-rated devices required)
    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_device_location_types_uuid UNIQUE (uuid),

    -- Global slugs must be unique across all global rows
    CONSTRAINT uq_device_location_types_global_slug
        UNIQUE NULLS NOT DISTINCT (tenant_id, slug),

    CONSTRAINT fk_device_location_types_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE CASCADE
);

CREATE INDEX idx_device_location_types_tenant_id ON device_location_types (tenant_id)
    WHERE tenant_id IS NOT NULL;
CREATE INDEX idx_device_location_types_slug      ON device_location_types (slug);
CREATE INDEX idx_device_location_types_is_active ON device_location_types (is_active);

CREATE TRIGGER trg_device_location_types_set_updated_at
    BEFORE UPDATE ON device_location_types
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Global default location types (tenant_id = NULL)
INSERT INTO device_location_types (tenant_id, slug, label, description, sort_order, is_external) VALUES
    (NULL, 'unit',           'Unit',                    'Inside a resident unit',                                           10,  FALSE),
    (NULL, 'hallway',        'Hallway',                 'Corridor or hallway on a residential floor',                       20,  FALSE),
    (NULL, 'lobby',          'Lobby',                   'Building entrance lobby or vestibule',                             30,  FALSE),
    (NULL, 'stairwell',      'Stairwell',               'Staircase or stairwell enclosure',                                 40,  FALSE),
    (NULL, 'elevator',       'Elevator',                'Inside or on top of an elevator cab or shaft',                     50,  FALSE),
    (NULL, 'parking_garage', 'Parking Garage',          'Interior structured parking garage',                               60,  FALSE),
    (NULL, 'parking_lot',    'Parking Lot',             'Surface-level outdoor parking area',                               70,  TRUE),
    (NULL, 'community_room', 'Community Room',          'Shared resident amenity room (clubhouse, lounge, etc.)',            80,  FALSE),
    (NULL, 'fitness_center', 'Fitness Center',          'Gym or fitness room',                                              90,  FALSE),
    (NULL, 'pool_area',      'Pool Area',               'Indoor or outdoor pool and surrounding deck',                     100,  FALSE),
    (NULL, 'rooftop',        'Rooftop',                 'Roof deck, rooftop amenity space, or rooftop equipment area',     110,  TRUE),
    (NULL, 'utility_room',   'Utility Room',            'General mechanical / electrical / utility room',                  120,  FALSE),
    (NULL, 'mdf',            'MDF / Telecom Closet',    'Main distribution frame or primary telecom/network closet',       130,  FALSE),
    (NULL, 'idf',            'IDF',                     'Intermediate distribution frame or satellite network closet',     140,  FALSE),
    (NULL, 'server_room',    'Server Room',             'Dedicated server or data closet (not a full DC)',                 150,  FALSE),
    (NULL, 'leasing_office', 'Leasing Office',          'Property management or leasing office',                           160,  FALSE),
    (NULL, 'mailroom',       'Mail Room',               'Package room, mail room, or parcel locker area',                  170,  FALSE),
    (NULL, 'laundry_room',   'Laundry Room',            'Common-area laundry facility',                                    180,  FALSE),
    (NULL, 'business_center','Business Center',         'Shared co-working or business center space',                      190,  FALSE),
    (NULL, 'courtyard',      'Courtyard',               'Open-air courtyard or interior outdoor common area',              200,  TRUE),
    (NULL, 'nema_enclosure', 'NEMA Enclosure',          'Equipment mounted in an exterior NEMA-rated weatherproof enclosure', 205, TRUE),
    (NULL, 'outdoor',        'Outdoor',                 'General outdoor area not covered by a more specific type',        210,  TRUE),
    (NULL, 'storage',        'Storage',                 'Storage room or storage unit area',                               220,  FALSE),
    (NULL, 'other',          'Other',                   'Location type not covered by any other category',                 999,  FALSE);

-- ---------------------------------------------------------------------------
-- network_devices
-- One row per physical piece of managed network equipment installed at a
-- property.  Provides identity, location, and operational status fields
-- common to all device types.  Type-specific detail lives in child tables
-- (access_points, switches, gateways).
-- ---------------------------------------------------------------------------
CREATE TABLE network_devices (
    id               BIGSERIAL           PRIMARY KEY,
    uuid             UUID                NOT NULL DEFAULT uuidv7(),
    tenant_id        BIGINT              NOT NULL,

    -- Ownership / location hierarchy — all three anchor to the same property;
    -- building_id and unit_id narrow the location further.
    property_id      BIGINT              NOT NULL,
    building_id      BIGINT,             -- NULL → location not tied to a specific building
    unit_id          BIGINT,             -- NULL → device is in a common area, not a unit

    -- Classification
    device_type      device_type         NOT NULL,
    status           device_status       NOT NULL DEFAULT 'provisioning',

    -- Physical identity
    manufacturer_id  BIGINT,             -- FK to manufacturers
    model            TEXT,
    serial_number    TEXT,               -- unique per manufacturer; see indexes below
    mac_address      MACADDR,            -- primary management / base MAC
    firmware_version TEXT,

    -- Network — management plane
    mgmt_ip          INET,

    -- Physical placement
    location_type_id     BIGINT,          -- FK → device_location_types; NULL = unclassified
    location_description TEXT,           -- e.g. "Above front door, near elevator 2"

    -- Lifecycle
    installed_at     TIMESTAMPTZ,
    last_seen_at     TIMESTAMPTZ,        -- updated by the NOC polling system

    -- SNMP poller responsible for monitoring this device.
    -- NULL = unassigned / monitoring not yet configured.
    poller_id        BIGINT,

    notes            TEXT,

    -- Timestamps
    created_at       TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    deleted_at       TIMESTAMPTZ,

    CONSTRAINT uq_network_devices_uuid UNIQUE (uuid),
    CONSTRAINT chk_network_devices_unit_needs_building CHECK (
        -- A unit always belongs to a building; if unit_id is set, building_id must be set
        unit_id IS NULL OR building_id IS NOT NULL
    ),

    CONSTRAINT fk_network_devices_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_network_devices_building
        FOREIGN KEY (building_id)
        REFERENCES buildings (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_network_devices_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_network_devices_manufacturer
        FOREIGN KEY (manufacturer_id)
        REFERENCES manufacturers (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_network_devices_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_network_devices_location_type
        FOREIGN KEY (location_type_id)
        REFERENCES device_location_types (id)
        ON DELETE SET NULL
);

-- Serial numbers are unique within a manufacturer's namespace
CREATE UNIQUE INDEX uq_network_devices_manufacturer_serial
    ON network_devices (manufacturer_id, serial_number)
    WHERE manufacturer_id IS NOT NULL
      AND serial_number IS NOT NULL
      AND deleted_at IS NULL;

-- Fallback uniqueness when no manufacturer is assigned
CREATE UNIQUE INDEX uq_network_devices_serial_no_manufacturer
    ON network_devices (serial_number)
    WHERE manufacturer_id IS NULL
      AND serial_number IS NOT NULL
      AND deleted_at IS NULL;

-- Only one device may hold a given MAC at a time
CREATE UNIQUE INDEX uq_network_devices_mac_address
    ON network_devices (mac_address)
    WHERE mac_address IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX idx_network_devices_tenant_id       ON network_devices (tenant_id);
CREATE INDEX idx_network_devices_property_id     ON network_devices (property_id);
CREATE INDEX idx_network_devices_building_id     ON network_devices (building_id);
CREATE INDEX idx_network_devices_unit_id         ON network_devices (unit_id);
CREATE INDEX idx_network_devices_manufacturer_id ON network_devices (manufacturer_id);
CREATE INDEX idx_network_devices_status          ON network_devices (status);
CREATE INDEX idx_network_devices_location_type_id ON network_devices (location_type_id)
    WHERE location_type_id IS NOT NULL;
CREATE INDEX idx_network_devices_device_type     ON network_devices (device_type);
CREATE INDEX idx_network_devices_poller_id       ON network_devices (poller_id)
    WHERE poller_id IS NOT NULL;
CREATE INDEX idx_network_devices_deleted_at      ON network_devices (deleted_at);

CREATE TRIGGER trg_network_devices_set_updated_at
    BEFORE UPDATE ON network_devices
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- IEEE 802.3 PoE standard and class that an AP requires from its switch port.
-- Standard determines the spec; class determines the power budget within that spec.
CREATE TYPE poe_standard AS ENUM (
    -- IEEE 802.3af — PoE (original)
    'ieee_802_3af',          -- up to 15.4 W delivered, 12.95 W at device

    -- IEEE 802.3at — PoE+ (Type 2)
    'ieee_802_3at',          -- up to 30 W delivered, 25.5 W at device

    -- IEEE 802.3bt — PoE++ (4-pair)
    'ieee_802_3bt_type3',    -- Type 3: up to 60 W delivered, 51 W at device
    'ieee_802_3bt_type4',    -- Type 4: up to 90 W delivered, 71.3 W at device

    -- Proprietary / pre-standard
    'ubiquiti_24v_passive',  -- Ubiquiti 24 V passive PoE (non-standard; no negotiation)
    'ubiquiti_48v_passive',  -- Ubiquiti 48 V passive PoE (non-standard; no negotiation)
    'cisco_upoe',            -- Cisco UPOE: up to 60 W over all 4 pairs (pre-bt)
    'cisco_upoe_plus',       -- Cisco UPOE+: up to 90 W (proprietary extension)

    'none',                  -- device is AC-powered; does not use PoE
    'other'                  -- non-standard / unknown proprietary scheme
);

-- IEEE 802.3bt PoE class (0–8) indicating negotiated power level.
-- Classes 0-3 map to 802.3af/at; 4-8 are 802.3bt-only.
CREATE TYPE poe_class AS ENUM (
    'class_0',   -- 0.44–12.94 W at device (802.3af default)
    'class_1',   -- 0.44–3.84 W at device
    'class_2',   -- 3.84–6.49 W at device
    'class_3',   -- 6.49–12.95 W at device (802.3af max)
    'class_4',   -- 12.95–25.5 W at device (802.3at max)
    'class_5',   -- 25.5–40 W at device (802.3bt Type 3, single-signature)
    'class_6',   -- 40–51 W at device  (802.3bt Type 3, dual-signature)
    'class_7',   -- 51–62 W at device  (802.3bt Type 4, single-signature)
    'class_8'    -- 62–71.3 W at device (802.3bt Type 4, dual-signature / max)
);

-- ---------------------------------------------------------------------------
-- access_points
-- AP-specific fields for every network_devices row whose device_type =
-- 'access_point'.  1-to-1 relationship enforced via UNIQUE on network_device_id.
-- ---------------------------------------------------------------------------
CREATE TABLE access_points (
    id                BIGSERIAL   PRIMARY KEY,
    uuid              UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id         BIGINT      NOT NULL,
    network_device_id BIGINT      NOT NULL,  -- 1:1 with network_devices
    ap_group_id       BIGINT,                -- NULL = not yet assigned to a group

    -- Radio capabilities (what the hardware supports)
    supports_2_4ghz   BOOLEAN     NOT NULL DEFAULT TRUE,
    supports_5ghz     BOOLEAN     NOT NULL DEFAULT TRUE,
    supports_6ghz     BOOLEAN     NOT NULL DEFAULT FALSE,  -- WiFi 6E / 7

    -- WiFi generation: 4 = 802.11n, 5 = 802.11ac, 6 = 802.11ax, 7 = 802.11be
    wifi_generation   SMALLINT    CHECK (wifi_generation BETWEEN 4 AND 7),

    -- Antenna / spatial streams per band (NULL if band not supported)
    max_spatial_streams_2_4ghz  SMALLINT CHECK (max_spatial_streams_2_4ghz BETWEEN 1 AND 16),
    max_spatial_streams_5ghz    SMALLINT CHECK (max_spatial_streams_5ghz    BETWEEN 1 AND 16),
    max_spatial_streams_6ghz    SMALLINT CHECK (max_spatial_streams_6ghz    BETWEEN 1 AND 16),

    -- Capacity
    max_clients       SMALLINT    CHECK (max_clients > 0),

    -- Power
    poe_standard      poe_standard,   -- PoE spec the AP requires
    poe_class         poe_class,       -- negotiated power class within that spec
    poe_watts         NUMERIC(5,1) CHECK (poe_watts > 0),
                      -- actual maximum draw in watts; overrides class-based estimate when known

    -- Physical form factor
    is_outdoor_rated  BOOLEAN     NOT NULL DEFAULT FALSE,
    is_ceiling_mount  BOOLEAN     NOT NULL DEFAULT TRUE,
    is_wall_mount     BOOLEAN     NOT NULL DEFAULT FALSE,

    -- Timestamps
    created_at  TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_access_points_uuid              UNIQUE (uuid),
    CONSTRAINT uq_access_points_network_device_id UNIQUE (network_device_id),
    CONSTRAINT chk_access_points_mount_exclusive  CHECK (
        NOT (is_ceiling_mount AND is_wall_mount)
    ),

    CONSTRAINT fk_access_points_network_device
        FOREIGN KEY (network_device_id)
        REFERENCES network_devices (id)
        ON DELETE CASCADE,   -- removing the base device removes the AP detail

    CONSTRAINT fk_access_points_ap_group
        FOREIGN KEY (ap_group_id)
        REFERENCES ap_groups (id)
        ON DELETE SET NULL,  -- ungrouping an AP keeps it as an unassigned device

    CONSTRAINT fk_access_points_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_access_points_tenant_id         ON access_points (tenant_id);
CREATE INDEX idx_access_points_network_device_id ON access_points (network_device_id);
CREATE INDEX idx_access_points_ap_group_id       ON access_points (ap_group_id);
CREATE INDEX idx_access_points_deleted_at        ON access_points (deleted_at);

CREATE TRIGGER trg_access_points_set_updated_at
    BEFORE UPDATE ON access_points
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- switches
-- Switch-specific fields for every network_devices row whose device_type =
-- 'switch'.  1-to-1 enforced via UNIQUE on network_device_id.
--
-- Physical location (MDF, IDF, utility room, etc.) is captured on the parent
-- network_devices row via location_type / location_description.
-- ---------------------------------------------------------------------------
CREATE TABLE switches (
    id                BIGSERIAL   PRIMARY KEY,
    uuid              UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id         BIGINT      NOT NULL,
    network_device_id BIGINT      NOT NULL,  -- 1:1 with network_devices
    uplink_device_id  BIGINT,                -- parent device in the hierarchy (NULL = root)

    -- Logical role within the network hierarchy
    role              switch_role NOT NULL DEFAULT 'access',

    -- Port inventory
    total_ports       SMALLINT    NOT NULL CHECK (total_ports > 0),
    poe_ports         SMALLINT    NOT NULL DEFAULT 0
                                  CHECK (poe_ports >= 0 AND poe_ports <= total_ports),
    uplink_ports      SMALLINT    NOT NULL DEFAULT 2
                                  CHECK (uplink_ports >= 0 AND uplink_ports <= total_ports),

    -- PoE budget
    poe_budget_watts  NUMERIC(7,1) CHECK (poe_budget_watts > 0),
                      -- total PoE power the switch can deliver across all ports

    -- Stacking
    is_stackable        BOOLEAN  NOT NULL DEFAULT FALSE,
    stack_member_count  SMALLINT          CHECK (stack_member_count > 0),
                        -- NULL = standalone; >1 = number of units in the stack

    -- Layer-3 capability
    is_layer3           BOOLEAN  NOT NULL DEFAULT FALSE,
                        -- TRUE if switch can route between VLANs

    -- Management VLAN
    mgmt_vlan_id        SMALLINT  CHECK (mgmt_vlan_id BETWEEN 1 AND 4094),

    -- Timestamps
    created_at  TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_switches_uuid              UNIQUE (uuid),
    CONSTRAINT uq_switches_network_device_id UNIQUE (network_device_id),
    CONSTRAINT chk_switches_stack_requires_stackable CHECK (
        stack_member_count IS NULL OR is_stackable = TRUE
    ),

    CONSTRAINT fk_switches_network_device
        FOREIGN KEY (network_device_id)
        REFERENCES network_devices (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_switches_uplink_device
        FOREIGN KEY (uplink_device_id)
        REFERENCES network_devices (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_switches_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_switches_tenant_id         ON switches (tenant_id);
CREATE INDEX idx_switches_network_device_id ON switches (network_device_id);
CREATE INDEX idx_switches_uplink_device_id  ON switches (uplink_device_id);
CREATE INDEX idx_switches_role              ON switches (role);
CREATE INDEX idx_switches_deleted_at        ON switches (deleted_at);

CREATE TRIGGER trg_switches_set_updated_at
    BEFORE UPDATE ON switches
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- gateways
-- A gateway is the default-router / CPE device that a block of units routes
-- through.  One property may have multiple gateways (e.g. one per building,
-- one per distribution switch tier, or for redundancy).
-- 1-to-1 with network_devices (device_type = 'gateway').
-- ---------------------------------------------------------------------------
CREATE TABLE gateways (
    id                BIGSERIAL       PRIMARY KEY,
    uuid              UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id         BIGINT          NOT NULL,
    network_device_id BIGINT          NOT NULL,

    -- Capacity / sizing
    max_units         SMALLINT        CHECK (max_units > 0),
                      -- advisory ceiling; not hard-enforced by DB

    -- NAT / routing
    is_nat_enabled    BOOLEAN         NOT NULL DEFAULT TRUE,
    is_ha_enabled     BOOLEAN         NOT NULL DEFAULT FALSE,
                      -- TRUE = deployed in high-availability pair (VRRP/HSRP/CARP)
    ha_peer_device_id BIGINT,         -- the other gateway in the HA pair

    notes             TEXT,

    -- Timestamps
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at        TIMESTAMPTZ,

    CONSTRAINT uq_gateways_uuid              UNIQUE (uuid),
    CONSTRAINT uq_gateways_network_device_id UNIQUE (network_device_id),
    CONSTRAINT chk_gateways_ha_peer_needs_ha CHECK (
        ha_peer_device_id IS NULL OR is_ha_enabled = TRUE
    ),

    CONSTRAINT fk_gateways_network_device
        FOREIGN KEY (network_device_id)
        REFERENCES network_devices (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_gateways_ha_peer
        FOREIGN KEY (ha_peer_device_id)
        REFERENCES network_devices (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_gateways_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_gateways_tenant_id         ON gateways (tenant_id);
CREATE INDEX idx_gateways_network_device_id ON gateways (network_device_id);
CREATE INDEX idx_gateways_ha_peer_device_id ON gateways (ha_peer_device_id);
CREATE INDEX idx_gateways_deleted_at        ON gateways (deleted_at);

CREATE TRIGGER trg_gateways_set_updated_at
    BEFORE UPDATE ON gateways
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- gateway_interfaces
-- Each gateway exposes one or more logical interfaces (physical ports, VLAN
-- sub-interfaces, tunnels, bridges, or LAGs).  This table captures the
-- identity, type, role, and current IP addressing of each interface.
--
-- IP addresses are recorded here as a transitional measure; a full IPAM
-- model (address blocks, allocations, pools) will be added in a later
-- migration and will supersede the ipv4_* / ipv6_* columns.
-- ---------------------------------------------------------------------------
CREATE TABLE gateway_interfaces (
    id          BIGSERIAL           PRIMARY KEY,
    uuid        UUID                NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT              NOT NULL,
    gateway_id  BIGINT              NOT NULL,

    -- Optionally scoped to the unit this interface serves (subscriber role).
    -- NULL for WAN, management, infrastructure, guest, or IoT interfaces.
    unit_id     BIGINT,

    -- Identity
    name        TEXT                NOT NULL,
                -- OS-level interface name: "eth0", "eth0.100", "wg0", "bond0"
    description TEXT,

    -- Classification
    interface_type  interface_type  NOT NULL,
    role            interface_role  NOT NULL DEFAULT 'other',

    -- 802.1Q VLAN tag — required when interface_type = 'vlan';
    -- may also be set on 'ethernet' to document the native/access VLAN.
    vlan_id         SMALLINT        CHECK (vlan_id BETWEEN 1 AND 4094),

    -- Link properties
    mac_address     MACADDR,
    mtu             SMALLINT        NOT NULL DEFAULT 1500
                                    CHECK (mtu BETWEEN 68 AND 9216),

    -- Operational state
    is_enabled      BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Routing next-hop addresses — the upstream router this interface points its
    -- default route at.  Relevant only for WAN interfaces; NULL for all others.
    -- Interface addresses are managed in ip_addresses; PD delegations from the
    -- ISP are recorded in ip_prefixes with role = 'wan_delegation'.
    ipv4_gateway    INET,
    ipv6_gateway    INET,

    -- Opaque identifier assigned by the poller for this interface.
    -- Used to retrieve per-interface traffic graphs from the poller's
    -- time-series API.  NULL until the poller has indexed the interface.
    poller_interface_ref    TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_gateway_interfaces_uuid         UNIQUE (uuid),
    -- Interface names are unique per gateway (OS enforces this; we mirror it)
    CONSTRAINT uq_gateway_interfaces_gateway_name UNIQUE (gateway_id, name),

    -- VLAN sub-interfaces must carry a VLAN ID
    CONSTRAINT chk_gateway_interfaces_vlan_type CHECK (
        interface_type != 'vlan' OR vlan_id IS NOT NULL
    ),
    -- Subscriber interfaces should be linked to a unit;
    -- non-subscriber interfaces should not be linked to a unit.
    CONSTRAINT chk_gateway_interfaces_subscriber_unit CHECK (
        (role = 'subscriber') = (unit_id IS NOT NULL)
    ),

    CONSTRAINT fk_gateway_interfaces_gateway
        FOREIGN KEY (gateway_id)
        REFERENCES gateways (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_gateway_interfaces_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_gateway_interfaces_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_gateway_interfaces_tenant_id  ON gateway_interfaces (tenant_id);
CREATE INDEX idx_gateway_interfaces_gateway_id ON gateway_interfaces (gateway_id);
CREATE INDEX idx_gateway_interfaces_unit_id    ON gateway_interfaces (unit_id)
    WHERE unit_id IS NOT NULL;
CREATE INDEX idx_gateway_interfaces_role       ON gateway_interfaces (role);
CREATE INDEX idx_gateway_interfaces_deleted_at ON gateway_interfaces (deleted_at);

CREATE TRIGGER trg_gateway_interfaces_set_updated_at
    BEFORE UPDATE ON gateway_interfaces
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- IPAM — IP Address Management
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enum Types (IPAM)
-- ---------------------------------------------------------------------------

CREATE TYPE ip_version AS ENUM (
    'ipv4',
    'ipv6'
);

-- Functional classification of a prefix within the addressing hierarchy
CREATE TYPE prefix_role AS ENUM (
    'rir_aggregate',    -- allocated to the tenant by a Regional Internet Registry
    'market_aggregate', -- ISP sub-allocation scoped to a market / region / PoP
    'wan_delegation',   -- prefix delegated from upstream ISP to a WAN handoff (e.g. IPv6 PD /56)
    'property_pool',    -- address pool available for assignment at a specific property
    'subscriber',       -- prefix delegated or statically assigned to a subscriber unit
    'infrastructure',   -- backbone / common-area / NOC services
    'management',       -- in-band or out-of-band device management addressing
    'loopback',         -- loopback or anycast ranges
    'other'
);

CREATE TYPE prefix_status AS ENUM (
    'container',    -- supernet used for organisation only; not directly assigned
    'active',       -- in active use
    'reserved',     -- held for future use; not yet assigned
    'deprecated'    -- retired; retained for audit history only
);

-- Regional Internet Registry that issued the allocation
CREATE TYPE rir AS ENUM (
    'arin',      -- American Registry for Internet Numbers
    'ripe',      -- RIPE NCC (Europe, Middle East, Central Asia)
    'apnic',     -- Asia-Pacific Network Information Centre
    'lacnic',    -- Latin America and Caribbean Network Information Centre
    'afrinic',   -- African Network Information Centre
    'iana',      -- IANA direct allocation (before RIR delegation)
    'private'    -- RFC 1918 / RFC 4193 / RFC 6598 / RFC 5737 reserved space
);

CREATE TYPE address_status AS ENUM (
    'active',       -- assigned to an interface and in use
    'reserved',     -- held; not yet assigned
    'dhcp',         -- managed by DHCP pool; not a static assignment record
    'deprecated',   -- IPv6 deprecated state (still valid but being retired)
    'anycast'       -- shared anycast address assigned to multiple interfaces
);

CREATE TYPE prefix_assignment_type AS ENUM (
    'delegated',    -- IPv6 prefix delegation per RFC 3633 / RFC 8415
    'purchased',    -- customer purchased a static IPv4 address block
    'reserved'      -- reserved for the unit; not yet active
);

-- ---------------------------------------------------------------------------
-- vrfs
-- A Virtual Routing and Forwarding instance defines an isolated routing
-- domain.  Prefixes in different VRFs may overlap without conflict, enabling
-- RFC 1918 address reuse across properties or MPLS L3VPN deployments.
--
-- The global routing table (public internet) is represented throughout the
-- IPAM model by vrf_id = NULL — no explicit "default VRF" row is required.
-- ---------------------------------------------------------------------------
CREATE TABLE vrfs (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,

    -- Display name, unique per tenant (e.g. "Global", "Prop-RFC1918", "MPLS-L3VPN-A")
    name        TEXT        NOT NULL,
    description TEXT,

    -- BGP Route Distinguisher for MPLS L3VPN; format: "ASN:NN" or "IP-addr:NN".
    -- NULL for non-MPLS / non-BGP VRFs.
    rd          TEXT,

    -- BGP route targets (import / export communities).  NULL if not BGP-controlled.
    rt_import   TEXT[],
    rt_export   TEXT[],

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_vrfs_uuid        UNIQUE (uuid),
    CONSTRAINT uq_vrfs_tenant_name UNIQUE (tenant_id, name),

    CONSTRAINT fk_vrfs_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_vrfs_tenant_id  ON vrfs (tenant_id);
CREATE INDEX idx_vrfs_deleted_at ON vrfs (deleted_at);

CREATE TRIGGER trg_vrfs_set_updated_at
    BEFORE UPDATE ON vrfs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ip_prefixes
-- Hierarchical registry of all IP prefixes managed by the tenant.  A single
-- table covers every level of the addressing hierarchy:
--
--   rir_aggregate  (e.g. 203.0.113.0/22 from ARIN)
--     └─ market_aggregate  (e.g. 203.0.113.0/23 — Northeast region)
--          └─ property_pool  (e.g. 203.0.113.0/24 — 123 Main St)
--               └─ subscriber  (e.g. 203.0.113.128/28 — unit 204)
--
--   IPv6 with Prefix Delegation:
--   rir_aggregate  (e.g. 2001:db8::/32)
--     └─ market_aggregate  (e.g. 2001:db8:1::/40)
--          └─ wan_delegation  (e.g. 2001:db8:1:100::/48 — ISP-issued PD to WAN)
--               └─ property_pool  (e.g. 2001:db8:1:100::/56)
--                    └─ subscriber  /64 delegated to an individual unit
--
-- Prefix uniqueness is scoped to a VRF:
--   vrf_id IS NULL       → global / public internet space; unique globally.
--   vrf_id IS NOT NULL   → private / VPN space; unique within that VRF.
-- ---------------------------------------------------------------------------
CREATE TABLE ip_prefixes (
    id              BIGSERIAL       PRIMARY KEY,
    uuid            UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT          NOT NULL,

    -- Routing domain.  NULL = global / public internet (no VRF row needed).
    vrf_id          BIGINT,

    -- Immediate parent in the prefix hierarchy.  NULL = top-level allocation.
    parent_id       BIGINT,

    -- The prefix itself.  PostgreSQL CIDR normalizes host bits automatically.
    prefix          CIDR            NOT NULL,

    -- Address family — stored explicitly for fast indexed queries; must match
    -- the actual family of the prefix value (enforced by CHECK constraint).
    ip_version      ip_version      NOT NULL,

    -- Classification
    role            prefix_role     NOT NULL DEFAULT 'other',
    status          prefix_status   NOT NULL DEFAULT 'active',

    -- RIR provenance — populate for rir_aggregate rows
    rir             rir,
    rir_handle      TEXT,           -- allocation ID, e.g. "NET-203-0-113-0-1" (ARIN)
    rir_allocated_at DATE,          -- date the RIR issued the allocation

    -- Property scope — set for property_pool and more-specific prefixes
    property_id     BIGINT,

    description     TEXT,
    notes           TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_ip_prefixes_uuid UNIQUE (uuid),

    CONSTRAINT chk_ip_prefixes_ip_version CHECK (
        (ip_version = 'ipv4' AND family(prefix) = 4)
        OR (ip_version = 'ipv6' AND family(prefix) = 6)
    ),

    CONSTRAINT fk_ip_prefixes_vrf
        FOREIGN KEY (vrf_id)
        REFERENCES vrfs (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ip_prefixes_parent
        FOREIGN KEY (parent_id)
        REFERENCES ip_prefixes (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ip_prefixes_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ip_prefixes_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

-- Uniqueness in public (global) space: no two active rows share the same CIDR
CREATE UNIQUE INDEX uq_ip_prefixes_global
    ON ip_prefixes (prefix)
    WHERE vrf_id IS NULL AND deleted_at IS NULL;

-- Uniqueness within a named VRF: the same CIDR is allowed in different VRFs
CREATE UNIQUE INDEX uq_ip_prefixes_vrf
    ON ip_prefixes (vrf_id, prefix)
    WHERE vrf_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX idx_ip_prefixes_tenant_id    ON ip_prefixes (tenant_id);
CREATE INDEX idx_ip_prefixes_vrf_id       ON ip_prefixes (vrf_id)      WHERE vrf_id IS NOT NULL;
CREATE INDEX idx_ip_prefixes_parent_id    ON ip_prefixes (parent_id)   WHERE parent_id IS NOT NULL;
CREATE INDEX idx_ip_prefixes_property_id  ON ip_prefixes (property_id) WHERE property_id IS NOT NULL;
CREATE INDEX idx_ip_prefixes_role         ON ip_prefixes (role);
CREATE INDEX idx_ip_prefixes_status       ON ip_prefixes (status);
CREATE INDEX idx_ip_prefixes_ip_version   ON ip_prefixes (ip_version);
CREATE INDEX idx_ip_prefixes_deleted_at   ON ip_prefixes (deleted_at);

-- GiST index enables fast containment queries using <<, >>, && operators,
-- e.g. "find the most-specific prefix containing 203.0.113.5":
--   SELECT * FROM ip_prefixes WHERE prefix >> '203.0.113.5' ORDER BY masklen(prefix) DESC
CREATE INDEX idx_ip_prefixes_prefix_gist
    ON ip_prefixes USING gist (prefix inet_ops);

CREATE TRIGGER trg_ip_prefixes_set_updated_at
    BEFORE UPDATE ON ip_prefixes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ip_addresses
-- Individual host addresses assigned to gateway interfaces.  Each row
-- belongs to a parent ip_prefix and may be bound to one gateway_interface.
--
-- address is stored as INET with the parent subnet's prefix length
-- (e.g. 203.0.113.2/30) so the network can be derived via network().
--
-- Uniqueness is enforced on the bare host IP — host() strips the mask —
-- within the routing domain (VRF) to prevent the same IP being recorded
-- twice with different mask lengths (e.g. /24 vs /32).
-- ---------------------------------------------------------------------------
CREATE TABLE ip_addresses (
    id                      BIGSERIAL       PRIMARY KEY,
    uuid                    UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id               BIGINT          NOT NULL,

    -- Routing domain — must match the parent prefix's vrf_id
    vrf_id                  BIGINT,

    -- Containing prefix (e.g. the /30 or /64 this address lives in)
    prefix_id               BIGINT          NOT NULL,

    -- Interface this address is configured on.  NULL = reserved / unassigned.
    gateway_interface_id    BIGINT,

    -- Host address with subnet mask, e.g. 203.0.113.2/30 or 2001:db8::1/64
    address                 INET            NOT NULL,
    ip_version              ip_version      NOT NULL,

    status                  address_status  NOT NULL DEFAULT 'active',

    -- Forward DNS hostname associated with this address (FQDN, optional)
    dns_name                TEXT,

    -- TRUE if this is the default-route first-hop for the subnet
    -- (the router address that hosts point their default route at)
    is_gateway              BOOLEAN         NOT NULL DEFAULT FALSE,

    description             TEXT,

    -- Timestamps
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at              TIMESTAMPTZ,

    CONSTRAINT uq_ip_addresses_uuid UNIQUE (uuid),

    CONSTRAINT chk_ip_addresses_ip_version CHECK (
        (ip_version = 'ipv4' AND family(address) = 4)
        OR (ip_version = 'ipv6' AND family(address) = 6)
    ),

    CONSTRAINT fk_ip_addresses_vrf
        FOREIGN KEY (vrf_id)
        REFERENCES vrfs (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ip_addresses_prefix
        FOREIGN KEY (prefix_id)
        REFERENCES ip_prefixes (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ip_addresses_gateway_interface
        FOREIGN KEY (gateway_interface_id)
        REFERENCES gateway_interfaces (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_ip_addresses_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

-- host() strips the prefix-length, returning the bare IP as text.
-- This prevents 10.0.0.1/24 and 10.0.0.1/32 from coexisting in one VRF.
CREATE UNIQUE INDEX uq_ip_addresses_global_host
    ON ip_addresses (host(address))
    WHERE vrf_id IS NULL AND deleted_at IS NULL;

CREATE UNIQUE INDEX uq_ip_addresses_vrf_host
    ON ip_addresses (vrf_id, host(address))
    WHERE vrf_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX idx_ip_addresses_tenant_id             ON ip_addresses (tenant_id);
CREATE INDEX idx_ip_addresses_vrf_id                ON ip_addresses (vrf_id) WHERE vrf_id IS NOT NULL;
CREATE INDEX idx_ip_addresses_prefix_id             ON ip_addresses (prefix_id);
CREATE INDEX idx_ip_addresses_gateway_interface_id  ON ip_addresses (gateway_interface_id)
    WHERE gateway_interface_id IS NOT NULL;
CREATE INDEX idx_ip_addresses_status                ON ip_addresses (status);
CREATE INDEX idx_ip_addresses_ip_version            ON ip_addresses (ip_version);
CREATE INDEX idx_ip_addresses_deleted_at            ON ip_addresses (deleted_at);

-- GiST index for address-within-subnet containment queries
CREATE INDEX idx_ip_addresses_address_gist
    ON ip_addresses USING gist (address inet_ops);

CREATE TRIGGER trg_ip_addresses_set_updated_at
    BEFORE UPDATE ON ip_addresses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- prefix_assignments
-- Records the delegation or static allocation of an ip_prefix to a unit.
-- Typical cases:
--   - IPv6 PD: a /56 or /60 delegated to a subscriber unit; the unit CPE
--     further sub-delegates /64 prefixes to its internal LANs.
--   - IPv4 block purchase: a static /28 or /29 sold to a business unit.
--   - Reservation: a prefix held for a unit before service activation.
--
-- gateway_interface_id captures which subscriber interface routes the delegated
-- prefix toward the unit.  NULL during pre-provisioning.
--
-- At most one active assignment per prefix is enforced by a partial unique
-- index on prefix_id where the record is current (ended_at IS NULL and not
-- soft-deleted).
-- ---------------------------------------------------------------------------
CREATE TABLE prefix_assignments (
    id                      BIGSERIAL               PRIMARY KEY,
    uuid                    UUID                    NOT NULL DEFAULT uuidv7(),
    tenant_id               BIGINT                  NOT NULL,

    prefix_id               BIGINT                  NOT NULL,
    unit_id                 BIGINT                  NOT NULL,

    -- Subscriber interface responsible for routing this prefix toward the unit.
    -- NULL = not yet provisioned / pre-activation reservation.
    gateway_interface_id    BIGINT,

    assignment_type         prefix_assignment_type  NOT NULL DEFAULT 'delegated',

    -- Active period; NULL ended_at = currently active
    started_at              TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    ended_at                TIMESTAMPTZ,

    notes                   TEXT,

    -- Timestamps
    created_at              TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    deleted_at              TIMESTAMPTZ,

    CONSTRAINT uq_prefix_assignments_uuid UNIQUE (uuid),

    CONSTRAINT chk_prefix_assignments_period CHECK (
        ended_at IS NULL OR ended_at > started_at
    ),

    CONSTRAINT fk_prefix_assignments_prefix
        FOREIGN KEY (prefix_id)
        REFERENCES ip_prefixes (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_prefix_assignments_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_prefix_assignments_gateway_interface
        FOREIGN KEY (gateway_interface_id)
        REFERENCES gateway_interfaces (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_prefix_assignments_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

-- At most one active assignment per prefix at any point in time
CREATE UNIQUE INDEX uq_prefix_assignments_active_prefix
    ON prefix_assignments (prefix_id)
    WHERE ended_at IS NULL AND deleted_at IS NULL;

CREATE INDEX idx_prefix_assignments_tenant_id             ON prefix_assignments (tenant_id);
CREATE INDEX idx_prefix_assignments_prefix_id             ON prefix_assignments (prefix_id);
CREATE INDEX idx_prefix_assignments_unit_id               ON prefix_assignments (unit_id);
CREATE INDEX idx_prefix_assignments_gateway_interface_id  ON prefix_assignments (gateway_interface_id)
    WHERE gateway_interface_id IS NOT NULL;
CREATE INDEX idx_prefix_assignments_started_at            ON prefix_assignments (started_at);
CREATE INDEX idx_prefix_assignments_ended_at              ON prefix_assignments (ended_at)
    WHERE ended_at IS NOT NULL;
CREATE INDEX idx_prefix_assignments_deleted_at            ON prefix_assignments (deleted_at);

CREATE TRIGGER trg_prefix_assignments_set_updated_at
    BEFORE UPDATE ON prefix_assignments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- unit_networks
-- Captures the Layer-2 and DHCP provisioning configuration for a unit's
-- dedicated network segment.  IP addressing is managed via the IPAM tables
-- (ip_prefixes / ip_addresses); this table holds only the data needed to
-- program the gateway and DHCP server:
--
--   gateway_id       — which gateway routes traffic for this unit
--   vlan_id          — 802.1Q tag that isolates this unit at L2
--   ipv4_prefix_id   — FK to the ip_prefixes row for the unit's IPv4 subnet
--                      (prefix_role = 'property_pool' or 'subscriber')
--   ipv4_dhcp_start/
--   ipv4_dhcp_end    — DHCP pool range carved from the IPv4 prefix
--   ipv4_dns_servers — ordered resolver list pushed to clients via DHCP
--   ipv6_mode        — how the unit receives IPv6 (disabled / SLAAC / DHCPv6)
--   ipv6_prefix_id   — FK to the ip_prefixes row for the delegated IPv6 prefix
--                      (prefix_role = 'subscriber', NULL when ipv6_mode = 'disabled')
--   ipv6_dns_servers — resolver list pushed to clients via RA / DHCPv6
--
-- The gateway router address for each prefix is tracked in ip_addresses
-- (is_gateway = TRUE) and is not duplicated here.
-- ---------------------------------------------------------------------------
CREATE TABLE unit_networks (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    unit_id     BIGINT      NOT NULL,
    gateway_id  BIGINT      NOT NULL,

    -- Layer 2
    vlan_id     SMALLINT    NOT NULL CHECK (vlan_id BETWEEN 1 AND 4094),

    -- IPv4 — subnet sourced from IPAM
    ipv4_prefix_id      BIGINT  NOT NULL,       -- FK → ip_prefixes
    ipv4_dhcp_start     INET    NOT NULL,
    ipv4_dhcp_end       INET    NOT NULL,
    ipv4_dns_servers    INET[]  NOT NULL DEFAULT '{}',
                        -- ordered list; application fills with provider defaults if empty

    -- IPv6 — provisioning mode + optional delegated prefix from IPAM
    ipv6_mode           ipv6_mode NOT NULL DEFAULT 'disabled',
    ipv6_prefix_id      BIGINT,                 -- FK → ip_prefixes; NULL when ipv6_mode = 'disabled'
    ipv6_dns_servers    INET[]  NOT NULL DEFAULT '{}',

    -- Provisioning state
    is_provisioned      BOOLEAN NOT NULL DEFAULT FALSE,
                        -- set TRUE once gateway/switch has been programmed

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_unit_networks_uuid    UNIQUE (uuid),
    CONSTRAINT uq_unit_networks_unit_id UNIQUE (unit_id),
                -- one active network per unit; soft-delete old row before re-provisioning

    CONSTRAINT chk_unit_networks_ipv4_dhcp_range CHECK (
        ipv4_dhcp_start <= ipv4_dhcp_end
    ),
    CONSTRAINT chk_unit_networks_ipv6_prefix_required CHECK (
        -- A delegated prefix is required for stateful IPv6 modes
        ipv6_mode = 'disabled'
        OR ipv6_mode = 'slaac'
        OR ipv6_prefix_id IS NOT NULL
    ),
    CONSTRAINT chk_unit_networks_ipv6_prefix_absent_when_disabled CHECK (
        -- No prefix should be linked when IPv6 is disabled
        ipv6_mode != 'disabled' OR ipv6_prefix_id IS NULL
    ),

    CONSTRAINT fk_unit_networks_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_unit_networks_gateway
        FOREIGN KEY (gateway_id)
        REFERENCES gateways (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_unit_networks_ipv4_prefix
        FOREIGN KEY (ipv4_prefix_id)
        REFERENCES ip_prefixes (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_unit_networks_ipv6_prefix
        FOREIGN KEY (ipv6_prefix_id)
        REFERENCES ip_prefixes (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_unit_networks_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

-- VLANs must be unique per gateway (within the same routing domain)
CREATE UNIQUE INDEX uq_unit_networks_gateway_vlan
    ON unit_networks (gateway_id, vlan_id)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_unit_networks_tenant_id      ON unit_networks (tenant_id);
CREATE INDEX idx_unit_networks_unit_id        ON unit_networks (unit_id);
CREATE INDEX idx_unit_networks_gateway_id     ON unit_networks (gateway_id);
CREATE INDEX idx_unit_networks_ipv4_prefix_id ON unit_networks (ipv4_prefix_id);
CREATE INDEX idx_unit_networks_ipv6_prefix_id ON unit_networks (ipv6_prefix_id)
    WHERE ipv6_prefix_id IS NOT NULL;
CREATE INDEX idx_unit_networks_deleted_at     ON unit_networks (deleted_at);

CREATE TRIGGER trg_unit_networks_set_updated_at
    BEFORE UPDATE ON unit_networks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- device_credentials
-- Management credentials for any network_devices row.  A device may have
-- multiple credential records (e.g. a primary SSH key + a read-only SNMP
-- community; or credentials rotating over time).
--
-- SECURITY: secret values are NEVER stored in plaintext.  The application
-- layer is responsible for encrypting before INSERT and decrypting after
-- SELECT.  secret_encrypted holds application-level ciphertext (AES-256-GCM
-- or similar).  Key management (e.g. AWS KMS, HashiCorp Vault) is handled
-- outside the database.
-- ---------------------------------------------------------------------------
CREATE TABLE device_credentials (
    id                BIGSERIAL           PRIMARY KEY,
    uuid              UUID                NOT NULL DEFAULT uuidv7(),
    tenant_id         BIGINT              NOT NULL,
    network_device_id BIGINT              NOT NULL,

    credential_type   credential_type     NOT NULL,
    label             TEXT,               -- human-readable note, e.g. "NOC read-only SNMP"

    -- Authentication principal (not always applicable for token/key types)
    username          TEXT,

    -- Encrypted secret: password, community string, private key, bearer token, etc.
    -- Application-encrypted ciphertext; see security note above.
    secret_encrypted  BYTEA,

    -- SSH public key (stored in plaintext — not secret)
    ssh_public_key    TEXT,

    -- SNMP v3 specific
    snmp_auth_protocol  TEXT,  -- 'MD5' | 'SHA' | 'SHA-256' | 'SHA-512'
    snmp_priv_protocol  TEXT,  -- 'DES' | 'AES128' | 'AES256'

    -- When multiple credentials of the same type exist, highest priority tried first
    priority          SMALLINT            NOT NULL DEFAULT 0,

    is_active         BOOLEAN             NOT NULL DEFAULT TRUE,

    -- Timestamps
    created_at        TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    deleted_at        TIMESTAMPTZ,

    CONSTRAINT uq_device_credentials_uuid UNIQUE (uuid),
    CONSTRAINT chk_device_credentials_snmp_v3_protocols CHECK (
        -- auth/priv protocols are only meaningful for SNMPv3
        credential_type = 'snmp_v3'
        OR (snmp_auth_protocol IS NULL AND snmp_priv_protocol IS NULL)
    ),
    CONSTRAINT chk_device_credentials_ssh_key_needs_public CHECK (
        credential_type != 'ssh_key' OR ssh_public_key IS NOT NULL
    ),

    CONSTRAINT fk_device_credentials_network_device
        FOREIGN KEY (network_device_id)
        REFERENCES network_devices (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_device_credentials_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_device_credentials_tenant_id          ON device_credentials (tenant_id);
CREATE INDEX idx_device_credentials_network_device_id ON device_credentials (network_device_id);
CREATE INDEX idx_device_credentials_credential_type   ON device_credentials (credential_type);
CREATE INDEX idx_device_credentials_deleted_at        ON device_credentials (deleted_at);

CREATE TRIGGER trg_device_credentials_set_updated_at
    BEFORE UPDATE ON device_credentials
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- oob_devices
-- OOB-specific detail for every network_devices row whose device_type =
-- 'other' (or a dedicated oob type once device_type is extended).
-- Follows the same 1:1 specialization pattern as access_points, switches,
-- and gateways: network_device_id is NOT NULL + UNIQUE, and CASCADE deletes
-- this row when the parent device row is removed.
--
-- Identity, physical location, manufacturer, model, serial number, MAC,
-- management IP, and lifecycle fields all live on the network_devices row.
-- This table holds only OOB-specific operational and cellular details.
-- Credentials (admin password, SIM PIN, etc.) are stored in device_credentials
-- referencing the same network_device_id.
-- ---------------------------------------------------------------------------

CREATE TYPE oob_device_type AS ENUM (
    'lte_modem',         -- 4G LTE USB or embedded modem
    '5g_modem',          -- 5G NR modem (sub-6 GHz or mmWave)
    'lte_router',        -- standalone LTE router/gateway (e.g. Cradlepoint, Peplink)
    '5g_router',         -- standalone 5G router/gateway
    'satellite',         -- satellite terminal (e.g. Starlink, Viasat)
    'dsl_backup',        -- xDSL secondary circuit used as backup
    'cable_backup',      -- cable/DOCSIS secondary circuit used as backup
    'fixed_wireless',    -- licensed or unlicensed fixed-wireless backup link
    'other'
);

CREATE TYPE oob_device_status AS ENUM (
    'active',       -- in service and reachable
    'standby',      -- configured but only activates on primary failure
    'degraded',     -- reachable but operating below normal (signal, throughput)
    'offline',      -- unreachable / powered off
    'decommissioned'
);

CREATE TABLE oob_devices (
    id                BIGSERIAL           PRIMARY KEY,
    uuid              UUID                NOT NULL DEFAULT uuidv7(),
    tenant_id         BIGINT              NOT NULL,
    network_device_id BIGINT              NOT NULL,  -- 1:1 with network_devices

    -- Classification
    device_type     oob_device_type     NOT NULL,
    oob_status      oob_device_status   NOT NULL DEFAULT 'standby',
                    -- OOB-specific operational state; complements network_devices.status

    -- SIM / carrier details (relevant for cellular types)
    carrier_name    TEXT,               -- e.g. "AT&T", "T-Mobile", "Verizon"
    iccid           TEXT,               -- SIM card ICCID (19–20 digit identifier)
    imei            TEXT,               -- modem IMEI
    phone_number    TEXT,               -- assigned MSISDN if carrier provides one
    apn             TEXT,               -- APN override if not using carrier default

    -- OOB management access (in addition to mgmt_ip on network_devices)
    mgmt_url        TEXT,               -- web UI or SSH jump URL for NOC access over OOB path

    -- Signal / connectivity telemetry (updated by poller or agent)
    signal_dbm      SMALLINT,           -- last known RSSI / RSRP in dBm

    notes           TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_oob_devices_uuid              UNIQUE (uuid),
    CONSTRAINT uq_oob_devices_network_device_id UNIQUE (network_device_id),

    CONSTRAINT fk_oob_devices_network_device
        FOREIGN KEY (network_device_id)
        REFERENCES network_devices (id)
        ON DELETE CASCADE,   -- removing the base device removes the OOB detail

    CONSTRAINT fk_oob_devices_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_oob_devices_tenant_id         ON oob_devices (tenant_id);
CREATE INDEX idx_oob_devices_network_device_id ON oob_devices (network_device_id);
CREATE INDEX idx_oob_devices_oob_status        ON oob_devices (oob_status);
CREATE INDEX idx_oob_devices_deleted_at        ON oob_devices (deleted_at);

CREATE TRIGGER trg_oob_devices_set_updated_at
    BEFORE UPDATE ON oob_devices
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- btree_gist is required for the range-exclusion constraint on service_accounts
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------------
-- service_plan_templates
-- Tenant-level master catalog of service tiers.  A tenant is the service
-- provider / ISP; templates represent the canonical plan definitions they
-- offer across their portfolio.  They are never directly sold to residents.
-- Instead, when a property is provisioned, the operator copies whichever
-- templates apply into that property's service_plans table, optionally
-- adjusting price or speed for that market.
--
-- Templates are immutable in the sense that once a service_plans row
-- references a template, the template row should only be retired
-- (is_active = FALSE) rather than deleted, to preserve audit lineage.
-- ---------------------------------------------------------------------------
CREATE TYPE service_account_status AS ENUM (
    'pending',    -- provisioned but service not yet active
    'active',     -- currently delivering service
    'suspended',  -- temporarily halted (non-payment, policy, etc.)
    'cancelled'   -- permanently terminated
);

CREATE TABLE service_plan_templates (
    id              BIGSERIAL       PRIMARY KEY,
    uuid            UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT          NOT NULL,

    -- Identity
    name            TEXT            NOT NULL,  -- e.g. "Starter 100", "Pro 500", "Gig 1000"
    description     TEXT,

    -- Speed (Mbps; 0 = unlimited / unthrottled)
    download_mbps   INTEGER         NOT NULL CHECK (download_mbps >= 0),
    upload_mbps     INTEGER         NOT NULL CHECK (upload_mbps >= 0),

    -- Pricing (serves as the default; property plans may override)
    price_per_month NUMERIC(10, 2)  NOT NULL CHECK (price_per_month >= 0),
    setup_fee       NUMERIC(10, 2)  NOT NULL DEFAULT 0.00 CHECK (setup_fee >= 0),

    -- Data cap (NULL = no cap)
    data_cap_gb     INTEGER         CHECK (data_cap_gb > 0),

    -- Availability
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
                    -- set FALSE to retire the template; existing property plans unaffected

    -- Timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_service_plan_templates_uuid        UNIQUE (uuid),
    CONSTRAINT uq_service_plan_templates_tenant_name UNIQUE (tenant_id, name),

    CONSTRAINT fk_service_plan_templates_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_service_plan_templates_tenant_id  ON service_plan_templates (tenant_id);
CREATE INDEX idx_service_plan_templates_is_active  ON service_plan_templates (is_active);
CREATE INDEX idx_service_plan_templates_deleted_at ON service_plan_templates (deleted_at);

CREATE TRIGGER trg_service_plan_templates_set_updated_at
    BEFORE UPDATE ON service_plan_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- service_plans
-- Property-scoped service tiers available for sale at a specific property.
-- Plans are created by copying a service_plan_template during property
-- provisioning (template_id records the origin) or by creating them
-- directly on the property.  After the copy, the plan is fully independent
-- and may be customised (price, speed, cap) for that property's market.
--
-- A plan record is immutable once it has been referenced by service accounts;
-- retire old plans with is_active = FALSE rather than deleting them.
-- ---------------------------------------------------------------------------
CREATE TABLE service_plans (
    id              BIGSERIAL       PRIMARY KEY,
    uuid            UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT          NOT NULL,
    organization_id BIGINT          NOT NULL,
    property_id     BIGINT          NOT NULL,

    -- Lineage: which template this plan was copied from, if any.
    -- NULL = plan was created directly on the property (no template source).
    template_id     BIGINT,

    -- Identity
    name            TEXT            NOT NULL,  -- e.g. "Starter 100", "Pro 500", "Gig 1000"
    description     TEXT,

    -- Speed (Mbps; 0 = unlimited / unthrottled)
    download_mbps   INTEGER         NOT NULL CHECK (download_mbps >= 0),
    upload_mbps     INTEGER         NOT NULL CHECK (upload_mbps >= 0),

    -- Pricing (may differ from the source template for this property's market)
    price_per_month NUMERIC(10, 2)  NOT NULL CHECK (price_per_month >= 0),
    setup_fee       NUMERIC(10, 2)  NOT NULL DEFAULT 0.00 CHECK (setup_fee >= 0),

    -- Data cap (NULL = no cap)
    data_cap_gb     INTEGER         CHECK (data_cap_gb > 0),

    -- Availability
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
                    -- set FALSE to retire the plan; existing accounts are unaffected

    -- Timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_service_plans_uuid          UNIQUE (uuid),
    CONSTRAINT uq_service_plans_property_name UNIQUE (property_id, name),

    CONSTRAINT fk_service_plans_organization
        FOREIGN KEY (organization_id)
        REFERENCES organizations (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_service_plans_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_service_plans_template
        FOREIGN KEY (template_id)
        REFERENCES service_plan_templates (id)
        ON DELETE SET NULL,
                    -- nullify lineage if the template is deleted; plan itself survives

    CONSTRAINT fk_service_plans_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_service_plans_tenant_id       ON service_plans (tenant_id);
CREATE INDEX idx_service_plans_organization_id ON service_plans (organization_id);
CREATE INDEX idx_service_plans_property_id     ON service_plans (property_id);
CREATE INDEX idx_service_plans_template_id     ON service_plans (template_id)
    WHERE template_id IS NOT NULL;
CREATE INDEX idx_service_plans_is_active       ON service_plans (is_active);
CREATE INDEX idx_service_plans_deleted_at      ON service_plans (deleted_at);

CREATE TRIGGER trg_service_plans_set_updated_at
    BEFORE UPDATE ON service_plans
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- service_accounts
-- Represents a contracted period of network service delivered to a unit.
-- A new row is created each time service starts (or restarts after a gap).
--
-- Overlap prevention: the EXCLUDE constraint guarantees that no two
-- service_accounts for the same unit have overlapping active date ranges.
-- ended_at = NULL means the service is ongoing (open-ended upper bound).
-- The tstzrange '[)' interval is half-open: includes started_at, excludes
-- ended_at — so back-to-back periods (end of one = start of next) are
-- permitted without triggering the exclusion.
-- ---------------------------------------------------------------------------
CREATE TABLE service_accounts (
    id              BIGSERIAL               PRIMARY KEY,
    uuid            UUID                    NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT                  NOT NULL,
    unit_id         BIGINT                  NOT NULL,
    service_plan_id BIGINT                  NOT NULL,

    -- Service period
    started_at      TIMESTAMPTZ             NOT NULL,
    ended_at        TIMESTAMPTZ,            -- NULL = currently active / no end date

    status          service_account_status  NOT NULL DEFAULT 'pending',

    -- Optional external reference (e.g. billing system account ID)
    external_ref    TEXT,

    notes           TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ             NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_service_accounts_uuid UNIQUE (uuid),

    CONSTRAINT chk_service_accounts_period CHECK (
        ended_at IS NULL OR ended_at > started_at
    ),

    -- Prevent overlapping service periods on the same unit.
    -- tstzrange('[)', NULL upper) = open-ended / currently active.
    CONSTRAINT excl_service_accounts_no_overlap
        EXCLUDE USING gist (
            unit_id WITH =,
            tstzrange(started_at, ended_at, '[)') WITH &&
        )
        WHERE (deleted_at IS NULL),

    CONSTRAINT fk_service_accounts_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_service_accounts_service_plan
        FOREIGN KEY (service_plan_id)
        REFERENCES service_plans (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_service_accounts_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_service_accounts_tenant_id       ON service_accounts (tenant_id);
CREATE INDEX idx_service_accounts_unit_id         ON service_accounts (unit_id);
CREATE INDEX idx_service_accounts_service_plan_id ON service_accounts (service_plan_id);
CREATE INDEX idx_service_accounts_status          ON service_accounts (status);
CREATE INDEX idx_service_accounts_started_at      ON service_accounts (started_at);
CREATE INDEX idx_service_accounts_ended_at        ON service_accounts (ended_at);
CREATE INDEX idx_service_accounts_deleted_at      ON service_accounts (deleted_at);

CREATE TRIGGER trg_service_accounts_set_updated_at
    BEFORE UPDATE ON service_accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- users
-- One row per human interacting with the portal.  The account persists for
-- the lifetime of the person's relationship with the platform regardless of
-- which units they live in or manage (residence/association is modelled
-- separately in user_units).
--
-- Authentication is via AWS Cognito; cognito_sub is the immutable Cognito
-- subject UUID issued at account creation and never changes.
-- ---------------------------------------------------------------------------

-- Coarse user class determining which portal surface the user accesses and
-- the baseline set of capabilities available to them.  Fine-grained
-- permissions within a class are stored as JSONB on the user row.
CREATE TYPE user_class AS ENUM (
    'resident',           -- tenant / occupant
    'property_manager',   -- on-site or portfolio property manager
    'noc_staff',          -- network operations center technician
    'admin'               -- full platform administrator (service provider staff)
);

CREATE TABLE users (
    id              BIGSERIAL       PRIMARY KEY,
    uuid            UUID            NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT          NOT NULL,

    -- Cognito identity link — set once at account creation, never updated
    cognito_sub     TEXT            NOT NULL,

    -- Profile
    given_name      TEXT            NOT NULL,
    family_name     TEXT            NOT NULL,
    email           CITEXT          NOT NULL,
    phone           TEXT,

    -- Portal access class (coarse)
    user_class      user_class      NOT NULL DEFAULT 'resident',

    -- Fine-grained permissions within the class, evaluated by the backend.
    -- Structure is application-defined; stored as JSONB for flexibility.
    -- Example: {"can_manage_billing": true, "can_submit_tickets": true}
    permissions     JSONB           NOT NULL DEFAULT '{}',

    -- Account state
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
                    -- FALSE = account suspended / deactivated; blocks login

    -- Timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,    -- soft-delete; does not remove Cognito account

    CONSTRAINT uq_users_uuid        UNIQUE (uuid),
    CONSTRAINT uq_users_cognito_sub UNIQUE (cognito_sub),
    CONSTRAINT uq_users_email       UNIQUE (email),

    CONSTRAINT fk_users_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_users_tenant_id  ON users (tenant_id);
CREATE INDEX idx_users_email      ON users (email);
CREATE INDEX idx_users_user_class ON users (user_class);
CREATE INDEX idx_users_is_active  ON users (is_active);
CREATE INDEX idx_users_deleted_at ON users (deleted_at);

CREATE TRIGGER trg_users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- user_units
-- Tracks which units a user is associated with.  A resident living in two
-- apartments has two rows; a property manager overseeing many units can have
-- many rows.  Unit association is independent of active service — a user
-- retains their history even after moving out.
-- ---------------------------------------------------------------------------
CREATE TABLE user_units (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    user_id     BIGINT      NOT NULL,
    unit_id     BIGINT      NOT NULL,

    -- Optional date range capturing when the association was / is active.
    -- NULL = no specific period (e.g. property manager with ongoing access).
    associated_from TIMESTAMPTZ,
    associated_to   TIMESTAMPTZ,    -- NULL = still associated

    is_primary  BOOLEAN     NOT NULL DEFAULT FALSE,
                -- marks the user's "home" unit for notification / billing purposes

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_user_units_uuid      UNIQUE (uuid),
    CONSTRAINT uq_user_units_user_unit UNIQUE (user_id, unit_id),
    CONSTRAINT chk_user_units_period CHECK (
        associated_to IS NULL OR associated_to > associated_from
    ),

    CONSTRAINT fk_user_units_user
        FOREIGN KEY (user_id)
        REFERENCES users (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_user_units_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_user_units_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_user_units_tenant_id  ON user_units (tenant_id);
CREATE INDEX idx_user_units_user_id    ON user_units (user_id);
CREATE INDEX idx_user_units_unit_id    ON user_units (unit_id);
CREATE INDEX idx_user_units_deleted_at ON user_units (deleted_at);

CREATE TRIGGER trg_user_units_set_updated_at
    BEFORE UPDATE ON user_units
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- service_account_users
-- M:M join: which users are associated with a service account.
-- A household may have multiple adults on the same account; a property
-- manager may be associated for billing/admin purposes.
-- ---------------------------------------------------------------------------
CREATE TABLE service_account_users (
    id                  BIGSERIAL   PRIMARY KEY,
    uuid                UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id           BIGINT      NOT NULL,
    service_account_id  BIGINT      NOT NULL,
    user_id             BIGINT      NOT NULL,

    is_primary          BOOLEAN     NOT NULL DEFAULT FALSE,
                        -- the financially responsible / primary contact for this account

    -- Timestamps
    created_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_service_account_users_uuid         UNIQUE (uuid),
    CONSTRAINT uq_service_account_users_account_user UNIQUE (service_account_id, user_id),

    CONSTRAINT fk_service_account_users_service_account
        FOREIGN KEY (service_account_id)
        REFERENCES service_accounts (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_service_account_users_user
        FOREIGN KEY (user_id)
        REFERENCES users (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_service_account_users_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_service_account_users_tenant_id           ON service_account_users (tenant_id);
CREATE INDEX idx_service_account_users_service_account_id ON service_account_users (service_account_id);
CREATE INDEX idx_service_account_users_user_id            ON service_account_users (user_id);
CREATE INDEX idx_service_account_users_deleted_at         ON service_account_users (deleted_at);

CREATE TRIGGER trg_service_account_users_set_updated_at
    BEFORE UPDATE ON service_account_users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- guest_users
-- Transient users of the network service at a property — visitors, contractors,
-- prospective residents, delivery personnel, etc.  Guest users are not full
-- platform users; they are verified by a one-time code sent to either an
-- email address or an SMS-capable phone number (at least one is required).
--
-- All other identity fields are optional; tenants configure which fields they
-- collect via their onboarding flow.  Tenant-specific data not covered by
-- typed columns goes in extra_data (JSONB).
-- ---------------------------------------------------------------------------

CREATE TYPE guest_user_type AS ENUM (
    'visitor',              -- personal guest / friend / family
    'contractor',           -- tradesperson, maintenance crew, vendor
    'prospective_resident', -- attending a property showing / leasing tour
    'delivery',             -- delivery driver, courier, food delivery
    'event_attendee',       -- attending a scheduled property event
    'corporate_guest',      -- business / corporate short-term tenant
    'other'
);

CREATE TYPE guest_user_status AS ENUM (
    'pending',   -- contact collected but OTP not yet confirmed
    'verified',  -- OTP confirmed; identity established
    'active',    -- within the granted access window and verified
    'expired',   -- access window has elapsed
    'revoked'    -- access manually revoked before expiry
);

CREATE TYPE guest_verification_channel AS ENUM (
    'email',
    'sms'
);

CREATE TABLE guest_users (
    id              BIGSERIAL                   PRIMARY KEY,
    uuid            UUID                        NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT                      NOT NULL,
    property_id     BIGINT                      NOT NULL,

    -- Classification
    guest_type      guest_user_type             NOT NULL DEFAULT 'visitor',
    status          guest_user_status           NOT NULL DEFAULT 'pending',

    -- Contact / identity — at least one of email or phone is required;
    -- enforced by CHECK constraint below.
    email           CITEXT,
    phone           TEXT,           -- E.164 recommended, e.g. +12125550100

    -- Optional personal details (tenant-configured; collect what's needed)
    given_name      TEXT,
    family_name     TEXT,
    company         TEXT,           -- employer / organization (useful for contractors)

    -- Purpose of visit (free-text; shown to property managers and NOC)
    purpose         TEXT,

    -- Access window
    access_starts_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    access_ends_at      TIMESTAMPTZ,        -- NULL = no fixed end (revoke manually)

    -- WiFi access group this guest should be placed on (e.g. the property guest SSID)
    ap_group_id         BIGINT,             -- NULL = application default / not yet assigned

    -- Verification outcome — the OTP value itself is NEVER stored here;
    -- only which channel was used and when the OTP was confirmed.
    verification_channel    guest_verification_channel,
    verified_at             TIMESTAMPTZ,    -- NULL = OTP not yet confirmed

    -- Sponsoring user — the resident or staff member who invited or admitted the guest
    sponsored_by_user_id    BIGINT,         -- NULL = self-registered (public kiosk flow)

    -- Tenant-specific fields not yet promoted to typed columns
    -- e.g. {"unit_visiting": "204", "vehicle_plate": "XYZ-123", "badge_number": "B-07"}
    extra_data      JSONB       NOT NULL DEFAULT '{}',

    notes           TEXT,

    -- Timestamps
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_guest_users_uuid UNIQUE (uuid),

    -- At least one contact method is required for OTP verification
    CONSTRAINT chk_guest_users_contact_required CHECK (
        email IS NOT NULL OR phone IS NOT NULL
    ),
    CONSTRAINT chk_guest_users_access_window CHECK (
        access_ends_at IS NULL OR access_ends_at > access_starts_at
    ),
    -- verified_at requires a channel and vice-versa
    CONSTRAINT chk_guest_users_verification_consistent CHECK (
        (verified_at IS NULL) = (verification_channel IS NULL)
    ),

    CONSTRAINT fk_guest_users_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_guest_users_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_guest_users_ap_group
        FOREIGN KEY (ap_group_id)
        REFERENCES ap_groups (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_guest_users_sponsor
        FOREIGN KEY (sponsored_by_user_id)
        REFERENCES users (id)
        ON DELETE SET NULL
);

CREATE INDEX idx_guest_users_tenant_id           ON guest_users (tenant_id);
CREATE INDEX idx_guest_users_property_id         ON guest_users (property_id);
CREATE INDEX idx_guest_users_status              ON guest_users (status);
CREATE INDEX idx_guest_users_guest_type          ON guest_users (guest_type);
CREATE INDEX idx_guest_users_email               ON guest_users (email)   WHERE email IS NOT NULL;
CREATE INDEX idx_guest_users_phone               ON guest_users (phone)   WHERE phone IS NOT NULL;
CREATE INDEX idx_guest_users_ap_group_id         ON guest_users (ap_group_id);
CREATE INDEX idx_guest_users_sponsored_by        ON guest_users (sponsored_by_user_id)
    WHERE sponsored_by_user_id IS NOT NULL;
CREATE INDEX idx_guest_users_access_ends_at      ON guest_users (access_ends_at)
    WHERE access_ends_at IS NOT NULL;  -- supports expiry sweeps
CREATE INDEX idx_guest_users_deleted_at          ON guest_users (deleted_at);

CREATE TRIGGER trg_guest_users_set_updated_at
    BEFORE UPDATE ON guest_users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

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

-- =============================================================================
-- SNMP Polling Infrastructure
-- =============================================================================

-- ---------------------------------------------------------------------------
-- pollers
-- A distributed SNMP polling agent responsible for monitoring network
-- devices.  Each poller has a geographic region and a set of credentials
-- the backend uses to authenticate API calls to it.
--
-- SECURITY: client_secret_encrypted holds application-encrypted ciphertext
-- (AES-256-GCM or similar).  The plaintext secret is never stored here;
-- key management is handled outside the database (e.g. AWS KMS, Vault).
-- ---------------------------------------------------------------------------
CREATE TABLE pollers (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,

    -- Identity
    name        TEXT        NOT NULL,   -- human-readable label, e.g. "us-east-1 poller"
    region      TEXT        NOT NULL,   -- geographic / logical region, e.g. "us-east-1"
    hostname    TEXT        NOT NULL,   -- DNS name or IP the backend uses to reach the poller

    -- API credentials — used by the backend to authenticate calls to this poller
    client_id               TEXT    NOT NULL,
    client_secret_encrypted BYTEA   NOT NULL,
                -- Application-encrypted ciphertext; see security note above.

    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,

    notes       TEXT,

    -- Timestamps
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_pollers_uuid              UNIQUE (uuid),
    CONSTRAINT uq_pollers_tenant_name       UNIQUE (tenant_id, name),
    CONSTRAINT uq_pollers_tenant_client_id  UNIQUE (tenant_id, client_id),

    CONSTRAINT fk_pollers_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_pollers_tenant_id  ON pollers (tenant_id);
CREATE INDEX idx_pollers_region     ON pollers (region);
CREATE INDEX idx_pollers_is_active  ON pollers (is_active);
CREATE INDEX idx_pollers_deleted_at ON pollers (deleted_at);

CREATE TRIGGER trg_pollers_set_updated_at
    BEFORE UPDATE ON pollers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Now that pollers exists, add the FK from network_devices.poller_id
ALTER TABLE network_devices
    ADD CONSTRAINT fk_network_devices_poller
        FOREIGN KEY (poller_id)
        REFERENCES pollers (id)
        ON DELETE SET NULL;



-- ---------------------------------------------------------------------------
-- ENUMs
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- ticket_category_types
-- Registry of ticket type codes.  System-provided defaults have tenant_id = NULL
-- and are shared across all tenants (read-only to tenants).  Tenants may add
-- their own types by inserting rows with their tenant_id set.
-- ---------------------------------------------------------------------------
CREATE TABLE ticket_category_types (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),

    -- NULL = system default (visible to all tenants, not deletable by tenants).
    -- Non-NULL = tenant-owned custom type.
    tenant_id   BIGINT,

    -- Machine-readable key used by the application for routing / SLA logic.
    -- System defaults use snake_case names matching the original enum values.
    name        TEXT        NOT NULL,

    -- Human-readable label shown in UIs.
    label       TEXT        NOT NULL,

    description TEXT,

    -- Whether tickets of this type are expected to be service-impacting.
    -- Used to pre-fill the impact field and set default SLA tiers.
    is_service_impacting    BOOLEAN NOT NULL DEFAULT FALSE,

    -- When TRUE, hide from resident-facing submission forms
    -- (e.g. 'provisioning_failure' is triggered by NOC / automation only).
    internal_only   BOOLEAN NOT NULL DEFAULT FALSE,

    -- Logical group tag for display / filtering (free-form, e.g. 'outage',
    -- 'device', 'billing', 'resident', 'operations', 'general').
    group_tag   TEXT,

    -- Sort order within the group_tag for UI rendering.
    display_order   SMALLINT NOT NULL DEFAULT 0,

    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_ticket_category_types_uuid UNIQUE (uuid),

    CONSTRAINT fk_ticket_category_types_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE CASCADE
);

-- System-default names must be globally unique; tenant names unique within tenant.
CREATE UNIQUE INDEX uq_ticket_category_types_system_name
    ON ticket_category_types (name)
    WHERE tenant_id IS NULL;

CREATE UNIQUE INDEX uq_ticket_category_types_tenant_name
    ON ticket_category_types (tenant_id, name)
    WHERE tenant_id IS NOT NULL;

CREATE INDEX idx_ticket_category_types_tenant_id  ON ticket_category_types (tenant_id);
CREATE INDEX idx_ticket_category_types_group_tag  ON ticket_category_types (group_tag);
CREATE INDEX idx_ticket_category_types_is_active  ON ticket_category_types (is_active);
CREATE INDEX idx_ticket_category_types_deleted_at ON ticket_category_types (deleted_at);

CREATE TRIGGER trg_ticket_category_types_set_updated_at
    BEFORE UPDATE ON ticket_category_types
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- Seed: system default ticket category types (tenant_id = NULL)
-- ---------------------------------------------------------------------------
INSERT INTO ticket_category_types
    (tenant_id, name, label, description, is_service_impacting, internal_only, group_tag, display_order)
VALUES
    -- Outage / service-impacting
    (NULL, 'property_wide_outage',      'Property-Wide Outage',       'All units at the property are down',                        TRUE,  TRUE,  'outage',      10),
    (NULL, 'building_outage',           'Building Outage',            'A single building within a property is down',               TRUE,  TRUE,  'outage',      20),
    (NULL, 'partial_outage',            'Partial Outage',             'A subset of units or floors are affected',                  TRUE,  TRUE,  'outage',      30),
    (NULL, 'unit_no_service',           'No Service',                 'This unit has no connectivity',                             TRUE,  FALSE, 'outage',      40),
    (NULL, 'intermittent_service',      'Intermittent Service',       'Unit experiences periodic drops or degradation',            TRUE,  FALSE, 'outage',      50),
    (NULL, 'slow_speeds',               'Slow Speeds',                'Throughput is well below the subscribed tier',              TRUE,  FALSE, 'outage',      60),
    -- Device / hardware
    (NULL, 'device_offline',            'Device Offline',             'Managed AP, switch, or gateway is unreachable',             TRUE,  TRUE,  'device',      10),
    (NULL, 'device_hardware_fault',     'Device Hardware Fault',      'Physical damage, power failure, or dead port',              TRUE,  TRUE,  'device',      20),
    (NULL, 'device_needs_replacement',  'Device Needs Replacement',   'RMA or scheduled swap required',                           FALSE, TRUE,  'device',      30),
    -- Configuration / provisioning
    (NULL, 'provisioning_failure',      'Provisioning Failure',       'New unit or device onboarding failed',                     TRUE,  TRUE,  'config',      10),
    (NULL, 'vlan_misconfiguration',     'VLAN Misconfiguration',      'VLAN or tagging error',                                    TRUE,  TRUE,  'config',      20),
    (NULL, 'ip_conflict',               'IP Conflict',                'Duplicate IP or DHCP pool exhaustion',                     TRUE,  TRUE,  'config',      30),
    (NULL, 'wifi_ssid_issue',           'WiFi SSID Issue',            'SSID not broadcasting or has wrong credentials',            TRUE,  FALSE, 'config',      40),
    (NULL, 'dns_resolution_failure',    'DNS Resolution Failure',     'DNS resolver is unreachable or returning bad data',         TRUE,  TRUE,  'config',      50),
    -- Billing / account
    (NULL, 'billing_dispute',           'Billing Dispute',            'Resident disputes a charge on an invoice',                 FALSE, FALSE, 'billing',     10),
    (NULL, 'payment_failure',           'Payment Failure',            'Failed payment; service is at risk of suspension',         FALSE, FALSE, 'billing',     20),
    (NULL, 'plan_upgrade_request',      'Plan Upgrade Request',       'Resident wants to move to a higher service tier',          FALSE, FALSE, 'billing',     30),
    (NULL, 'plan_downgrade_request',    'Plan Downgrade Request',     'Resident wants to move to a lower service tier',           FALSE, FALSE, 'billing',     40),
    (NULL, 'service_cancellation_request', 'Service Cancellation',   'Move-out or cancellation request',                        FALSE, FALSE, 'billing',     50),
    -- Resident / end-user
    (NULL, 'credential_reset',          'Credential Reset',           'WiFi password or portal login reset needed',               FALSE, FALSE, 'resident',    10),
    (NULL, 'device_registration',       'Device Registration',        'Resident wants to add or remove a managed device',         FALSE, FALSE, 'resident',    20),
    (NULL, 'coverage_complaint',        'Coverage Complaint',         'Weak WiFi signal in unit or common area',                  TRUE,  FALSE, 'resident',    30),
    (NULL, 'latency_complaint',         'Latency Complaint',          'High latency affecting gaming, VoIP, or video calls',      TRUE,  FALSE, 'resident',    40),
    (NULL, 'security_concern',          'Security Concern',           'Suspected unauthorized access or network abuse',           FALSE, FALSE, 'resident',    50),
    -- Property operations
    (NULL, 'maintenance_coordination',  'Maintenance Coordination',   'ISP must coordinate access with property staff',           FALSE, TRUE,  'operations',  10),
    (NULL, 'planned_maintenance_window','Planned Maintenance Window', 'Scheduled downtime, e.g. backbone or equipment work',      FALSE, TRUE,  'operations',  20),
    (NULL, 'smart_home_integration',    'Smart Home Integration',     'IoT, smart-lock, or smart-thermostat setup assistance',    FALSE, FALSE, 'operations',  30),
    (NULL, 'bulk_tv_issue',             'Bulk TV Issue',              'IPTV or bulk cable service problem',                       TRUE,  FALSE, 'operations',  40),
    (NULL, 'voip_issue',                'VoIP Issue',                 'Managed VoIP phone problem',                               TRUE,  FALSE, 'operations',  50),
    -- General / non-service-impacting
    (NULL, 'general_inquiry',           'General Inquiry',            'Question about service, portal features, etc.',            FALSE, FALSE, 'general',     10),
    (NULL, 'feature_request',           'Feature Request',            'Resident or PM asks for a platform feature',              FALSE, FALSE, 'general',     20),
    (NULL, 'feedback',                  'Feedback',                   'General feedback; no action required',                    FALSE, FALSE, 'general',     30),
    (NULL, 'other',                     'Other',                      'Catch-all; requires manual categorisation after creation', FALSE, FALSE, 'general',     99);

-- Whether the ticket is currently service-impacting.
CREATE TYPE ticket_impact AS ENUM (
    'critical',     -- 100 % of affected scope (property / building / unit) is down
    'high',         -- majority of users affected or near-total degradation
    'medium',       -- subset of users affected or significant degradation
    'low',          -- minor degradation, workaround available
    'none'          -- no service impact (billing, inquiry, feedback, etc.)
);

-- Urgency rating — separate from impact so matrix-based SLA is possible.
CREATE TYPE ticket_urgency AS ENUM (
    'critical',     -- must be resolved immediately (e.g. 24/7 NOC escalation)
    'high',
    'medium',
    'low'
);

-- Lifecycle state of the ticket.
CREATE TYPE ticket_status AS ENUM (
    'open',             -- newly created, not yet assigned
    'in_progress',      -- assignee is actively working it
    'pending_resident', -- waiting for information or action from the resident
    'pending_property', -- waiting for property management access / cooperation
    'pending_vendor',   -- waiting on a third-party or upstream carrier
    'resolved',         -- fix confirmed; monitoring period may still apply
    'closed',           -- verified resolved and closed out
    'cancelled'         -- duplicate, spam, or withdrawn by submitter
);

-- Source channel through which the ticket originated.
CREATE TYPE ticket_source AS ENUM (
    'resident_portal',      -- submitted by a resident through the web/app portal
    'property_manager',     -- submitted by property management
    'noc_internal',         -- opened by NOC staff proactively (e.g. alert-driven)
    'email',                -- inbound email-to-ticket
    'phone',                -- phone call logged by support staff
    'automated_alert',      -- auto-opened from a monitoring / alerting rule
    'api'                   -- opened via the OAuth2 API by an integration
);

-- Priority is derived (impact × urgency) but also stored explicitly so that
-- staff can override the computed value.
CREATE TYPE ticket_priority AS ENUM (
    'p1',   -- critical / emergency
    'p2',   -- high
    'p3',   -- medium
    'p4',   -- low / informational
    'p5'    -- deferred / backlog
);

-- ---------------------------------------------------------------------------
-- ticket_categories
-- Hierarchical, two-level taxonomy (parent → child).
-- Leaf categories are attached to tickets; root categories are groupings only.
-- Seeded with defaults but fully extensible per tenant.
-- ---------------------------------------------------------------------------
CREATE TABLE ticket_categories (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,

    parent_id   BIGINT,             -- NULL = root/group category
    name        TEXT        NOT NULL,
    description TEXT,

    -- FK to the ticket_category_types registry.
    -- NULL on group (root) rows; required on leaf rows.
    category_type_id    BIGINT,

    -- When TRUE this category is hidden from resident-facing ticket forms
    -- (e.g. "provisioning_failure" triggered only by NOC / automation).
    internal_only   BOOLEAN NOT NULL DEFAULT FALSE,

    -- Sort order within the parent group for UI rendering.
    display_order   SMALLINT NOT NULL DEFAULT 0,

    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT uq_ticket_categories_uuid        UNIQUE (uuid),
    CONSTRAINT uq_ticket_categories_tenant_name UNIQUE (tenant_id, parent_id, name),

    CONSTRAINT fk_ticket_categories_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ticket_categories_parent
        FOREIGN KEY (parent_id)
        REFERENCES ticket_categories (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ticket_categories_category_type
        FOREIGN KEY (category_type_id)
        REFERENCES ticket_category_types (id)
        ON DELETE RESTRICT,

    -- Leaf rows must have a category_type_id; root rows must not.
    CONSTRAINT chk_ticket_categories_type_on_leaf
        CHECK (
            (parent_id IS NULL AND category_type_id IS NULL)
            OR
            (parent_id IS NOT NULL AND category_type_id IS NOT NULL)
        )
);

CREATE INDEX idx_ticket_categories_tenant_id       ON ticket_categories (tenant_id);
CREATE INDEX idx_ticket_categories_parent_id       ON ticket_categories (parent_id);
CREATE INDEX idx_ticket_categories_category_type_id ON ticket_categories (category_type_id);
CREATE INDEX idx_ticket_categories_is_active       ON ticket_categories (is_active);
CREATE INDEX idx_ticket_categories_deleted_at      ON ticket_categories (deleted_at);

CREATE TRIGGER trg_ticket_categories_set_updated_at
    BEFORE UPDATE ON ticket_categories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- support_tickets
-- One row per ticket.  Scoped to a property; unit_id is optional to support
-- property-wide incidents as well as per-unit issues.
-- ---------------------------------------------------------------------------
CREATE TABLE support_tickets (
    id              BIGSERIAL   PRIMARY KEY,
    uuid            UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id       BIGINT      NOT NULL,

    -- Ticket number shown to users: auto-incrementing per tenant.
    -- Stored rather than computed so it is stable and indexable.
    ticket_number   BIGSERIAL               NOT NULL,   -- human-readable "#1001"

    -- Location
    property_id     BIGINT      NOT NULL,
    unit_id         BIGINT,     -- NULL → property-wide or building-wide incident

    -- Classification
    category_id         BIGINT  NOT NULL,   -- leaf ticket_categories row
    category_type_id    BIGINT  NOT NULL,
                        -- denormalized FK to ticket_category_types for fast filtering / routing
                        -- kept in sync by the application on ticket creation

    impact          ticket_impact   NOT NULL DEFAULT 'none',
    urgency         ticket_urgency  NOT NULL DEFAULT 'low',
    priority        ticket_priority NOT NULL DEFAULT 'p4',
    source          ticket_source   NOT NULL DEFAULT 'resident_portal',
    status          ticket_status   NOT NULL DEFAULT 'open',

    -- Content
    subject         TEXT        NOT NULL,
    description     TEXT        NOT NULL,

    -- People
    -- submitted_by_user_id: NULL if opened by automation / unauthenticated alert.
    submitted_by_user_id    BIGINT,
    -- assigned_to_user_id: NULL = unassigned (sits in the queue).
    assigned_to_user_id     BIGINT,

    -- Resolution
    resolved_at     TIMESTAMPTZ,    -- set when status → 'resolved'
    closed_at       TIMESTAMPTZ,    -- set when status → 'closed'
    resolution_note TEXT,           -- brief summary of how it was resolved

    -- SLA tracking
    -- sla_due_at is calculated and stored by the backend when the ticket is created.
    sla_due_at      TIMESTAMPTZ,
    sla_breached    BOOLEAN NOT NULL DEFAULT FALSE,
                    -- set TRUE by a background job if resolved_at > sla_due_at

    -- If this ticket was opened automatically from a monitoring alert, store
    -- a reference so the alert can be correlated and auto-closed.
    alert_reference TEXT,           -- opaque ID from the monitoring system

    -- When a property-wide outage ticket covers multiple subordinate unit
    -- tickets, track the parent here.
    parent_ticket_id BIGINT,

    notes           TEXT,           -- internal staff notes (not visible to residents)

    -- Timestamps
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT uq_support_tickets_uuid          UNIQUE (uuid),
    CONSTRAINT uq_support_tickets_tenant_number UNIQUE (tenant_id, ticket_number),

    CONSTRAINT fk_support_tickets_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_support_tickets_property
        FOREIGN KEY (property_id)
        REFERENCES properties (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_support_tickets_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_support_tickets_category
        FOREIGN KEY (category_id)
        REFERENCES ticket_categories (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_support_tickets_category_type
        FOREIGN KEY (category_type_id)
        REFERENCES ticket_category_types (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_support_tickets_submitted_by
        FOREIGN KEY (submitted_by_user_id)
        REFERENCES users (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_support_tickets_assigned_to
        FOREIGN KEY (assigned_to_user_id)
        REFERENCES users (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_support_tickets_parent
        FOREIGN KEY (parent_ticket_id)
        REFERENCES support_tickets (id)
        ON DELETE SET NULL,

    -- Resolved/closed timestamps must be consistent with status.
    CONSTRAINT chk_support_tickets_resolved_at
        CHECK (
            (status NOT IN ('resolved', 'closed') AND resolved_at IS NULL)
            OR (status IN ('resolved', 'closed') AND resolved_at IS NOT NULL)
        ),

    CONSTRAINT chk_support_tickets_closed_at
        CHECK (
            (status <> 'closed' AND closed_at IS NULL)
            OR (status = 'closed' AND closed_at IS NOT NULL)
        )
);

CREATE INDEX idx_support_tickets_tenant_id         ON support_tickets (tenant_id);
CREATE INDEX idx_support_tickets_property_id       ON support_tickets (property_id);
CREATE INDEX idx_support_tickets_unit_id           ON support_tickets (unit_id);
CREATE INDEX idx_support_tickets_category_id       ON support_tickets (category_id);
CREATE INDEX idx_support_tickets_category_type_id  ON support_tickets (category_type_id);
CREATE INDEX idx_support_tickets_status            ON support_tickets (status);
CREATE INDEX idx_support_tickets_priority          ON support_tickets (priority);
CREATE INDEX idx_support_tickets_impact            ON support_tickets (impact);
CREATE INDEX idx_support_tickets_submitted_by      ON support_tickets (submitted_by_user_id);
CREATE INDEX idx_support_tickets_assigned_to       ON support_tickets (assigned_to_user_id);
CREATE INDEX idx_support_tickets_parent_ticket_id  ON support_tickets (parent_ticket_id);
CREATE INDEX idx_support_tickets_sla_due_at        ON support_tickets (sla_due_at);
CREATE INDEX idx_support_tickets_created_at        ON support_tickets (created_at);
CREATE INDEX idx_support_tickets_deleted_at        ON support_tickets (deleted_at);

-- Partial index: open (unresolved, non-cancelled) tickets per property for dashboards.
CREATE INDEX idx_support_tickets_open_by_property
    ON support_tickets (property_id, priority, created_at)
    WHERE status NOT IN ('resolved', 'closed', 'cancelled') AND deleted_at IS NULL;

CREATE TRIGGER trg_support_tickets_set_updated_at
    BEFORE UPDATE ON support_tickets
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ticket_comments
-- Threaded comments / activity entries on a ticket.
-- Both public (resident-visible) and internal (staff-only) comments are stored
-- in the same table, differentiated by is_internal.
-- ---------------------------------------------------------------------------

CREATE TYPE ticket_comment_type AS ENUM (
    'comment',          -- human-authored message
    'status_change',    -- automated entry when status transitions
    'assignment_change',-- automated entry when assignee changes
    'priority_change',  -- automated entry when priority changes
    'system_note'       -- other automated activity entry
);

CREATE TABLE ticket_comments (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    ticket_id   BIGINT      NOT NULL,

    comment_type    ticket_comment_type NOT NULL DEFAULT 'comment',

    -- NULL for automated system entries (status_change, assignment_change, etc.)
    author_user_id  BIGINT,

    body        TEXT        NOT NULL,

    -- TRUE = visible to NOC/PM staff only; FALSE = visible to resident submitter too
    is_internal BOOLEAN     NOT NULL DEFAULT FALSE,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,   -- soft-delete; content preserved for audit

    CONSTRAINT uq_ticket_comments_uuid UNIQUE (uuid),

    CONSTRAINT fk_ticket_comments_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ticket_comments_ticket
        FOREIGN KEY (ticket_id)
        REFERENCES support_tickets (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ticket_comments_author
        FOREIGN KEY (author_user_id)
        REFERENCES users (id)
        ON DELETE SET NULL
);

CREATE INDEX idx_ticket_comments_ticket_id  ON ticket_comments (ticket_id);
CREATE INDEX idx_ticket_comments_tenant_id  ON ticket_comments (tenant_id);
CREATE INDEX idx_ticket_comments_author     ON ticket_comments (author_user_id);
CREATE INDEX idx_ticket_comments_created_at ON ticket_comments (created_at);
CREATE INDEX idx_ticket_comments_deleted_at ON ticket_comments (deleted_at);

CREATE TRIGGER trg_ticket_comments_set_updated_at
    BEFORE UPDATE ON ticket_comments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ticket_attachments
-- Files attached to a ticket or to a specific comment.
-- Actual file bytes live in object storage (e.g. S3); only metadata is stored here.
-- ---------------------------------------------------------------------------
CREATE TABLE ticket_attachments (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id   BIGINT      NOT NULL,
    ticket_id   BIGINT      NOT NULL,

    -- NULL when attached to the ticket itself; set when attached to a comment.
    comment_id  BIGINT,

    uploaded_by_user_id BIGINT,     -- NULL if uploaded by automation

    -- Object storage reference
    storage_key     TEXT    NOT NULL,   -- S3 key or equivalent object path
    filename        TEXT    NOT NULL,   -- original filename presented by the uploader
    content_type    TEXT    NOT NULL,   -- MIME type, e.g. "image/png"
    size_bytes      BIGINT  NOT NULL CHECK (size_bytes > 0),

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ,   -- soft-delete; object storage cleanup handled separately

    CONSTRAINT uq_ticket_attachments_uuid UNIQUE (uuid),

    CONSTRAINT fk_ticket_attachments_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ticket_attachments_ticket
        FOREIGN KEY (ticket_id)
        REFERENCES support_tickets (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_ticket_attachments_comment
        FOREIGN KEY (comment_id)
        REFERENCES ticket_comments (id)
        ON DELETE SET NULL,

    CONSTRAINT fk_ticket_attachments_uploaded_by
        FOREIGN KEY (uploaded_by_user_id)
        REFERENCES users (id)
        ON DELETE SET NULL
);

CREATE INDEX idx_ticket_attachments_ticket_id  ON ticket_attachments (ticket_id);
CREATE INDEX idx_ticket_attachments_comment_id ON ticket_attachments (comment_id);
CREATE INDEX idx_ticket_attachments_tenant_id  ON ticket_attachments (tenant_id);
CREATE INDEX idx_ticket_attachments_deleted_at ON ticket_attachments (deleted_at);

-- ---------------------------------------------------------------------------
-- ticket_watchers
-- Users subscribed to notifications for a specific ticket.
-- The ticket submitter and assignee receive notifications by application logic;
-- this table captures additional explicit subscriptions.
-- ---------------------------------------------------------------------------
CREATE TABLE ticket_watchers (
    id          BIGSERIAL   PRIMARY KEY,
    ticket_id   BIGINT      NOT NULL,
    user_id     BIGINT      NOT NULL,
    tenant_id   BIGINT      NOT NULL,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_ticket_watchers_ticket_user UNIQUE (ticket_id, user_id),

    CONSTRAINT fk_ticket_watchers_ticket
        FOREIGN KEY (ticket_id)
        REFERENCES support_tickets (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_ticket_watchers_user
        FOREIGN KEY (user_id)
        REFERENCES users (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_ticket_watchers_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_ticket_watchers_ticket_id ON ticket_watchers (ticket_id);
CREATE INDEX idx_ticket_watchers_user_id   ON ticket_watchers (user_id);
CREATE INDEX idx_ticket_watchers_tenant_id ON ticket_watchers (tenant_id);


-- Enum: ethernet_jack_room_type
-- Identifies the room or space where an ethernet jack is located.
-- ---------------------------------------------------------------------------
CREATE TYPE ethernet_jack_room_type AS ENUM (
    'bedroom',
    'living_room',
    'dining_room',
    'kitchen',
    'office',
    'hallway',
    'bathroom',
    'utility_closet',   -- telco/panel closet, wiring cabinet, etc.
    'common_area',      -- lobby, mail room, break room for commercial units
    'other'
);

-- ---------------------------------------------------------------------------
-- unit_ethernet_jacks
-- One row per physical ethernet jack (wall drop) inside a unit.
--
-- Columns:
--   room_type    — which room the jack is in
--   room_number  — disambiguates multiple rooms of the same type
--                  (e.g. room_number=1 for "Bedroom 1", room_number=2 for
--                  "Bedroom 2").  NULL for room types that can only appear once
--                  (kitchen, living room, etc.).
--   jack_index   — 1-based position when multiple jacks exist in the same
--                  room (e.g. jack_index=1 and jack_index=2 for two drops in
--                  the living room).  Defaults to 1.
--   label        — optional human-readable identifier matching any physical
--                  label on the wall plate or patch panel (e.g. "LR-1",
--                  "BR2-B", "PANEL-3").
--   network_device_id — optional FK to the switch (or other network device)
--                  this jack terminates at in the IDF/MDF.
--   switch_port  — free-text port identifier on network_device_id,
--                  e.g. "GE0/0/4", "eth3", "Port 7".
--   is_active    — FALSE if the jack is known to be unused, capped, or
--                  out of service.
--   notes        — installation notes, last-tested date, known issues, etc.
-- ---------------------------------------------------------------------------
CREATE TABLE unit_ethernet_jacks (
    id                  BIGSERIAL   PRIMARY KEY,
    uuid                UUID        NOT NULL DEFAULT uuidv7(),
    tenant_id           BIGINT      NOT NULL,
    unit_id             BIGINT      NOT NULL,

    -- Location
    room_type           ethernet_jack_room_type NOT NULL,
    room_number         SMALLINT    CHECK (room_number >= 1),   -- NULL when unambiguous
    jack_index          SMALLINT    NOT NULL DEFAULT 1 CHECK (jack_index >= 1),
    label               TEXT,       -- matches physical wall-plate / patch-panel marking

    -- Upstream termination (optional — fill in when known for faster NOC triage)
    network_device_id   BIGINT,     -- NULL until patched into switch inventory
    switch_port         TEXT,       -- e.g. "GE0/0/4" — only meaningful if network_device_id set

    -- Status
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    notes               TEXT,

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ,

    CONSTRAINT uq_unit_ethernet_jacks_uuid UNIQUE (uuid),

    CONSTRAINT fk_unit_ethernet_jacks_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_unit_ethernet_jacks_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_unit_ethernet_jacks_network_device
        FOREIGN KEY (network_device_id)
        REFERENCES network_devices (id)
        ON DELETE SET NULL,

    -- Enforce that switch_port is only set when a device is linked
    CONSTRAINT chk_unit_ethernet_jacks_switch_port
        CHECK (switch_port IS NULL OR network_device_id IS NOT NULL),

    -- Within a unit, each (room_type, room_number, jack_index) triple must be unique
    CONSTRAINT uq_unit_ethernet_jacks_location
        UNIQUE NULLS NOT DISTINCT (unit_id, room_type, room_number, jack_index)
);

CREATE INDEX idx_unit_ethernet_jacks_tenant_id         ON unit_ethernet_jacks (tenant_id);
CREATE INDEX idx_unit_ethernet_jacks_unit_id           ON unit_ethernet_jacks (unit_id);
CREATE INDEX idx_unit_ethernet_jacks_network_device_id ON unit_ethernet_jacks (network_device_id);
CREATE INDEX idx_unit_ethernet_jacks_is_active         ON unit_ethernet_jacks (is_active);
CREATE INDEX idx_unit_ethernet_jacks_deleted_at        ON unit_ethernet_jacks (deleted_at);

CREATE TRIGGER trg_unit_ethernet_jacks_set_updated_at
    BEFORE UPDATE ON unit_ethernet_jacks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
