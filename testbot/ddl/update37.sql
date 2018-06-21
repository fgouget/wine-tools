USE winetestbot;

ALTER TABLE VMs
  MODIFY Type ENUM('win32', 'win64', 'build', 'wine') NOT NULL;
