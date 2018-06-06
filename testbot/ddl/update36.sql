USE winetestbot;

ALTER TABLE Jobs
  MODIFY Status ENUM('new', 'staging', 'queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled') NOT NULL;
