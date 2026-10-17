-- Table for Plano's conversation state, from Plano's docs (docs/source/resources/db_setup/conversation_states.sql).
CREATE TABLE IF NOT EXISTS conversation_states (
    response_id TEXT PRIMARY KEY,
    input_items JSONB NOT NULL,
    created_at BIGINT NOT NULL,
    model TEXT NOT NULL,
    provider TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for common query patterns
CREATE INDEX IF NOT EXISTS idx_conversation_states_created_at
    ON conversation_states(created_at);

CREATE INDEX IF NOT EXISTS idx_conversation_states_provider
    ON conversation_states(provider);
