// A small payload. The demo needs something to give a version to, and to release !.
const VERSION = process.env.APP_VERSION || 'dev';
console.log(`service up — version ${VERSION}`);
