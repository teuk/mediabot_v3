package Mediabot::AI::Limits;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK=qw(REQUEST_TEXT_CHARS HTTP_RESPONSE_BYTES RESULT_JSON_BYTES WORKER_OUTPUT_BYTES response_size_message);
use constant {
    REQUEST_TEXT_CHARS => 250_000,
    HTTP_RESPONSE_BYTES => 512 * 1024,
    RESULT_JSON_BYTES => 240 * 1024,
    WORKER_OUTPUT_BYTES => 256 * 1024,
};
# Leave room for AsyncWorker's terminal envelope/newline. Count the encoded
# result, not just answer characters: JSON escaping and source metadata matter.
sub response_size_message {
    return 'The AI response exceeded its safe size limit. Please request a shorter answer.';
}
1;
