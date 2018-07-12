USE winetestbot;

ALTER TABLE Steps
  MODIFY FileType ENUM('none', 'exe32', 'exe64', 'patchdlls', 'patchprograms', 'patch') NOT NULL;

UPDATE Steps
  SET FileType = 'patch'
  WHERE FileType = 'patchdlls' OR FileType = 'patchprograms';

ALTER TABLE Steps
  MODIFY FileType ENUM('none', 'exe32', 'exe64', 'patch') NOT NULL;
