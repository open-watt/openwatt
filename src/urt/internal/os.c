#pragma attribute(push, nothrow, nogc)

#if defined(__linux)
# define _DEFAULT_SOURCE
# include <sys/socket.h>
# include <sys/un.h>
# include <netinet/in.h>
# include <netinet/ip.h>
# include <netinet/tcp.h>
# include <netdb.h>
#endif
