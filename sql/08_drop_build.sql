-- =============================================================================
-- 08_drop_build.sql — remove the build database
-- The demo tables in {{DB}}.PUBLIC are independent clones, so the build
-- database (generation helpers, planted-scenario plans, golden-answer SQL) can
-- go. Dropping it keeps planted answers out of reach of Cortex Sense and agents.
-- =============================================================================

USE ROLE {{ROLE}};
DROP DATABASE IF EXISTS {{BUILD_DB}};
