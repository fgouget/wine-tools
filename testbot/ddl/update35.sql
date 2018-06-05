USE winetestbot;

ALTER TABLE Steps
  MODIFY FileName VARCHAR(100) NULL,
  MODIFY FileType ENUM('none', 'exe32', 'exe64', 'patchdlls', 'patchprograms') NOT NULL;
