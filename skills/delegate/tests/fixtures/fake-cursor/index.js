const fs = require('fs');

const argsFile = process.env.FAKE_CURSOR_ARGS_FILE;
if (argsFile) {
    fs.writeFileSync(argsFile, JSON.stringify(process.argv.slice(2)), 'utf8');
}

const result = JSON.stringify({
    status: 'done',
    summary: 'fake',
    files_changed: [],
    tests_run: [],
    open_questions: []
});
const line = JSON.stringify({
    type: 'result',
    subtype: 'success',
    is_error: false,
    result: result,
    session_id: 'fake-session'
});
process.stdout.write(line + '\n');
