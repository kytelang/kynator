/* A deliberately non-Kyte "foreign" server: reads $PORT, binds it, and replies to each TCP connection
 * with its port and the FOO env var, so a Kynator supervision test can prove env + port delivery.
 * Build: gcc -O2 -o app server.c   (see ../build.sh) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <netinet/in.h>
#include <sys/socket.h>

int main(void) {
    const char *ps = getenv("PORT");
    int port = ps ? atoi(ps) : 8080;
    const char *foo = getenv("FOO");
    if (!foo) foo = "(unset)";

    int s = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = htons(port);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) { perror("bind"); return 1; }
    listen(s, 16);
    fprintf(stderr, "foreign C server listening on PORT=%d FOO=%s\n", port, foo);

    for (;;) {
        int c = accept(s, 0, 0);
        if (c < 0) continue;
        char body[128];
        int n = snprintf(body, sizeof body, "FOREIGN-OK port=%d FOO=%s\n", port, foo);
        char hdr[128];
        int h = snprintf(hdr, sizeof hdr,
                         "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", n);
        ssize_t _w1 = write(c, hdr, h);
        ssize_t _w2 = write(c, body, n);
        (void)_w1; (void)_w2;
        close(c);
    }
    return 0;
}
