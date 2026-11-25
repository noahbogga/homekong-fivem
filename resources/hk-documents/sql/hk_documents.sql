-- hk-documents schema
-- Documents and templates. The full payload lives in `data` (JSON), but we
-- normalize the columns needed for server-side authorization and fast lookup
-- so the server never has to trust or parse client input to enforce access.

CREATE TABLE IF NOT EXISTS `hk_documents` (
    `id`        INT(11)      NOT NULL AUTO_INCREMENT,
    `data`      LONGTEXT     NOT NULL,                 -- JSON document payload
    `ownerId`   VARCHAR(64)  NOT NULL,                 -- qb citizenid of holder
    `issuerId`  VARCHAR(64)  DEFAULT NULL,             -- qb citizenid of issuer
    `job`       VARCHAR(64)  DEFAULT NULL,             -- issuing job (branding)
    `docType`   VARCHAR(32)  NOT NULL DEFAULT 'a4',    -- license | a4 | certificate
    `isCopy`    TINYINT(1)   NOT NULL DEFAULT 0,       -- 0 = issued original, 1 = copy
    `createdAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_owner`  (`ownerId`),
    KEY `idx_issuer` (`issuerId`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `hk_document_templates` (
    `id`        INT(11)      NOT NULL AUTO_INCREMENT,
    `data`      LONGTEXT     NOT NULL,                 -- JSON template payload
    `job`       VARCHAR(64)  NOT NULL,                 -- owning job
    `docType`   VARCHAR(32)  NOT NULL DEFAULT 'a4',
    `minGrade`  INT(11)      DEFAULT NULL,             -- min job grade to issue
    `createdBy` VARCHAR(64)  DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_job` (`job`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
