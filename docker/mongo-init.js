// Runs once, on first initialization of an empty data directory.
// Creates the least-privilege application user that the app connects with,
// so the app never uses the root account.
db.getSiblingDB('TaskManager').createUser({
  user: process.env.MONGO_APP_USERNAME,
  pwd: process.env.MONGO_APP_PASSWORD,
  roles: [{ role: 'readWrite', db: 'TaskManager' }],
});
