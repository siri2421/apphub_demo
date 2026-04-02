-- Run this once against the AlloyDB postgres database after infrastructure is provisioned.

CREATE TABLE IF NOT EXISTS users (
    user_id   VARCHAR(64) PRIMARY KEY,
    user_name VARCHAR(255) NOT NULL
);

INSERT INTO users (user_id, user_name) VALUES
    ('u1', 'Alice Smith'),
    ('u2', 'Bob Jones'),
    ('u3', 'Carol Williams')
ON CONFLICT (user_id) DO NOTHING;
