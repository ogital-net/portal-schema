-- =============================================================================
-- V2: Support Ticketing System
--
-- Tables (in dependency order):
--   ticket_category_types   — extensible type registry; system defaults + per-tenant additions
--   ticket_categories       — two-level category taxonomy (parent / child)
--   support_tickets         — per-property tickets, optionally linked to a unit
--   ticket_comments         — threaded comment / activity log per ticket
--   ticket_attachments      — files attached to a ticket or a comment
--   ticket_watchers         — users subscribed to ticket notifications
-- =============================================================================

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
    (NULL, 'security_concern',          'Security Concern',           'Suspected unauthorised access or network abuse',           FALSE, FALSE, 'resident',    50),
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
                        -- denormalised FK to ticket_category_types for fast filtering / routing
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
