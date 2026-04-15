-- =============================================================================
-- V1: Initial Schema
--
-- Tables (in dependency order):
--   organizations       — service provider / ISP accounts
--   properties          — physical buildings / complexes
--   buildings           — individual structures within a property
--   units               — individual rentable spaces
--   manufacturers       — hardware vendor registry
--   ap_groups           — WiFi configuration profiles (SSID, security, VLAN)
--   network_devices     — all managed network equipment at a property
--   access_points       — AP-specific detail (1:1 with network_devices)
--   switches            — switch-specific detail (1:1 with network_devices)
--   gateways            — gateway-specific detail (1:1 with network_devices)
--   unit_networks       — per-unit VLAN + IPv4/IPv6 network config
--   device_credentials  — encrypted management credentials per device
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

-- Coarse categorization of where a device is physically installed.  Detailed
-- free-text goes in network_devices.location_description.
CREATE TYPE device_location_type AS ENUM (
    'unit',
    'hallway',
    'lobby',
    'stairwell',
    'elevator',
    'parking_garage',
    'parking_lot',
    'community_room',
    'fitness_center',
    'pool_area',
    'rooftop',
    'utility_room',
    'mdf',           -- main distribution frame / telecom closet
    'idf',           -- intermediate distribution frame
    'outdoor',
    'storage',
    'other'
);

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

-- ---------------------------------------------------------------------------
-- organizations
-- The top-level service-provider / ISP entity that owns and operates
-- one or more properties.
-- ---------------------------------------------------------------------------
CREATE TABLE organizations (
    id           BIGSERIAL    PRIMARY KEY,
    uuid         UUID         NOT NULL DEFAULT uuidv7(),

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

    CONSTRAINT uq_organizations_uuid  UNIQUE (uuid),
    CONSTRAINT uq_organizations_name  UNIQUE (name),
    CONSTRAINT chk_organizations_country_len CHECK (char_length(country) = 2)
);

CREATE INDEX idx_organizations_deleted_at ON organizations (deleted_at);

CREATE TRIGGER trg_organizations_set_updated_at
    BEFORE UPDATE ON organizations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- properties
-- A physical property (building, complex, campus) managed by an organization.
-- One organization may own many properties.
-- ---------------------------------------------------------------------------
CREATE TABLE properties (
    id              BIGSERIAL       PRIMARY KEY,
    uuid            UUID            NOT NULL DEFAULT uuidv7(),
    organization_id BIGINT          NOT NULL,

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
        ON DELETE RESTRICT
);

CREATE INDEX idx_properties_organization_id ON properties (organization_id);
CREATE INDEX idx_properties_deleted_at      ON properties (deleted_at);

-- Spatial lookup: find all properties within a bounding box
CREATE INDEX idx_properties_geo ON properties (latitude, longitude)
    WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

CREATE TRIGGER trg_properties_set_updated_at
    BEFORE UPDATE ON properties
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
    year_built      SMALLINT,
    total_floors    SMALLINT,
    construction_type TEXT,   -- e.g. "wood frame", "steel", "masonry", "concrete"

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
        ON DELETE RESTRICT
);

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
    property_id BIGINT      NOT NULL,
    building_id BIGINT,     -- NULL → unit belongs directly to the property

    -- Identity
    unit_number TEXT        NOT NULL, -- "101", "B-204", "PH-3", "Ground Retail"
    floor       SMALLINT,             -- floor level; 0 = ground, negative = below grade

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

    CONSTRAINT uq_manufacturers_uuid       UNIQUE (uuid),
    CONSTRAINT uq_manufacturers_name       UNIQUE (name),
    CONSTRAINT uq_manufacturers_short_name UNIQUE (short_name)
);

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
        ON DELETE RESTRICT
);

CREATE INDEX idx_ap_groups_property_id ON ap_groups (property_id);
CREATE INDEX idx_ap_groups_deleted_at  ON ap_groups (deleted_at);

CREATE TRIGGER trg_ap_groups_set_updated_at
    BEFORE UPDATE ON ap_groups
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

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
    location_type        device_location_type NOT NULL DEFAULT 'other',
    location_description TEXT,           -- e.g. "Above front door, near elevator 2"

    -- Lifecycle
    installed_at     TIMESTAMPTZ,
    last_seen_at     TIMESTAMPTZ,        -- updated by the NOC polling system

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
        ON DELETE RESTRICT
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

CREATE INDEX idx_network_devices_property_id     ON network_devices (property_id);
CREATE INDEX idx_network_devices_building_id     ON network_devices (building_id);
CREATE INDEX idx_network_devices_unit_id         ON network_devices (unit_id);
CREATE INDEX idx_network_devices_manufacturer_id ON network_devices (manufacturer_id);
CREATE INDEX idx_network_devices_status          ON network_devices (status);
CREATE INDEX idx_network_devices_device_type     ON network_devices (device_type);
CREATE INDEX idx_network_devices_deleted_at      ON network_devices (deleted_at);

CREATE TRIGGER trg_network_devices_set_updated_at
    BEFORE UPDATE ON network_devices
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- access_points
-- AP-specific fields for every network_devices row whose device_type =
-- 'access_point'.  1-to-1 relationship enforced via UNIQUE on network_device_id.
-- ---------------------------------------------------------------------------
CREATE TABLE access_points (
    id                BIGSERIAL   PRIMARY KEY,
    uuid              UUID        NOT NULL DEFAULT uuidv7(),
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
    poe_standard      TEXT,       -- e.g. "802.3af", "802.3at", "802.3bt", "proprietary"
    poe_watts         NUMERIC(5,1) CHECK (poe_watts > 0),

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
        ON DELETE SET NULL   -- ungrouping an AP keeps it as an unassigned device
);

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
        ON DELETE SET NULL
);

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
    network_device_id BIGINT          NOT NULL,

    -- WAN / upstream handoff (the interface facing the ISP or upstream router)
    wan_ip            INET,           -- assigned WAN address (NULL if DHCP/PPPoE)
    wan_subnet        CIDR,           -- e.g. 203.0.113.0/30
    wan_gateway       INET,           -- upstream next-hop (ISP handoff)

    -- IPv6 WAN
    wan_ipv6_prefix   CIDR,           -- delegated prefix from ISP (PD), e.g. /56
    wan_ipv6_gateway  INET,

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
        ON DELETE SET NULL
);

CREATE INDEX idx_gateways_network_device_id ON gateways (network_device_id);
CREATE INDEX idx_gateways_ha_peer_device_id ON gateways (ha_peer_device_id);
CREATE INDEX idx_gateways_deleted_at        ON gateways (deleted_at);

CREATE TRIGGER trg_gateways_set_updated_at
    BEFORE UPDATE ON gateways
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- unit_networks
-- Each unit is assigned exactly one dedicated Layer-2/Layer-3 network segment.
-- The VLAN provides L2 isolation; the IPv4/IPv6 parameters are pushed to the
-- gateway and DHCP server during provisioning.
-- ---------------------------------------------------------------------------
CREATE TABLE unit_networks (
    id          BIGSERIAL   PRIMARY KEY,
    uuid        UUID        NOT NULL DEFAULT uuidv7(),
    unit_id     BIGINT      NOT NULL,
    gateway_id  BIGINT      NOT NULL,

    -- Layer 2
    vlan_id     SMALLINT    NOT NULL CHECK (vlan_id BETWEEN 1 AND 4094),

    -- IPv4
    ipv4_subnet         CIDR    NOT NULL,       -- e.g. 10.100.1.0/24
    ipv4_gateway        INET    NOT NULL,        -- first usable / router address
    ipv4_dhcp_start     INET    NOT NULL,
    ipv4_dhcp_end       INET    NOT NULL,
    ipv4_dns_servers    INET[]  NOT NULL DEFAULT '{}',
                        -- ordered list; application fills with provider defaults if empty

    -- IPv6
    ipv6_mode           ipv6_mode NOT NULL DEFAULT 'disabled',
    ipv6_prefix         CIDR,   -- assigned /64 (or smaller) for this unit
    ipv6_gateway        INET,
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
    CONSTRAINT chk_unit_networks_ipv6_fields CHECK (
        -- prefix and gateway required for stateful IPv6 modes
        ipv6_mode = 'disabled'
        OR ipv6_mode = 'slaac'
        OR (ipv6_prefix IS NOT NULL AND ipv6_gateway IS NOT NULL)
    ),

    CONSTRAINT fk_unit_networks_unit
        FOREIGN KEY (unit_id)
        REFERENCES units (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_unit_networks_gateway
        FOREIGN KEY (gateway_id)
        REFERENCES gateways (id)
        ON DELETE RESTRICT
);

-- VLANs must be unique per gateway (within the same routing domain)
CREATE UNIQUE INDEX uq_unit_networks_gateway_vlan
    ON unit_networks (gateway_id, vlan_id)
    WHERE deleted_at IS NULL;

CREATE INDEX idx_unit_networks_unit_id    ON unit_networks (unit_id);
CREATE INDEX idx_unit_networks_gateway_id ON unit_networks (gateway_id);
CREATE INDEX idx_unit_networks_deleted_at ON unit_networks (deleted_at);

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
        ON DELETE CASCADE
);

CREATE INDEX idx_device_credentials_network_device_id ON device_credentials (network_device_id);
CREATE INDEX idx_device_credentials_credential_type   ON device_credentials (credential_type);
CREATE INDEX idx_device_credentials_deleted_at        ON device_credentials (deleted_at);

CREATE TRIGGER trg_device_credentials_set_updated_at
    BEFORE UPDATE ON device_credentials
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
