-- =============================================================================
-- 99_teardown.sql — remove everything the lab created
-- Run with `python3 scripts/lab.py teardown --yes`, which first deletes the
-- Cortex Sense context ({{DB}}.CORTEX_SENSE.{{SENSE_CONTEXT}}) through the builder API.
-- Ontology deletes must go relationships -> representations -> nodes -> domain.
-- =============================================================================

USE ROLE {{ROLE}};

SELECT SYSTEM$DELETE_ALL_GLOSSARY_RELATIONSHIPS('{"domainFilter":"{{ONTOLOGY_DOMAIN}}"}') AS R;
SELECT SYSTEM$DELETE_ALL_GLOSSARY_ASSOCIATIONS('{"domainFilter":"{{ONTOLOGY_DOMAIN}}"}') AS R;
SELECT SYSTEM$DELETE_ALL_GLOSSARY_TERM_DRAFTS('{"domainFilter":"{{ONTOLOGY_DOMAIN}}"}') AS R;
SELECT SYSTEM$DELETE_ALL_GLOSSARY_TERMS('{"domainFilter":"{{ONTOLOGY_DOMAIN}}"}') AS R;
SELECT SYSTEM$DELETE_GLOSSARY_DOMAIN('{{ONTOLOGY_DOMAIN}}') AS R;

DROP DATABASE IF EXISTS {{DB}};
DROP DATABASE IF EXISTS {{BUILD_DB}};
DROP WAREHOUSE IF EXISTS {{WH}};
