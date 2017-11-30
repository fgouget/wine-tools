USE winetestbot;

ALTER TABLE Records
  MODIFY Type         ENUM('engine', 'tasks', 'vmresult', 'vmresult', 'vmstatus') NOT NULL;
