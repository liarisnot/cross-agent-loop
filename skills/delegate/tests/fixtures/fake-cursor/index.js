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
