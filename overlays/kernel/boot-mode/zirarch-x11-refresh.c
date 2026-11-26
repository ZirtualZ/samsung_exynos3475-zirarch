#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define FBIOGET_VSCREENINFO 0x4600
#define FBIOPAN_DISPLAY 0x4606

int main(void)
{
	unsigned char screeninfo[160];
	int fd = open("/dev/fb0", O_RDWR);

	if (fd < 0)
		return 1;
	if (ioctl(fd, FBIOGET_VSCREENINFO, screeninfo) < 0) {
		close(fd);
		return 2;
	}
	for (;;) {
		if (ioctl(fd, FBIOPAN_DISPLAY, screeninfo) < 0) {
			struct timespec sleep_time = {
				.tv_sec = 0,
				.tv_nsec = 100000000,
			};
			nanosleep(&sleep_time, NULL);
			ioctl(fd, FBIOGET_VSCREENINFO, screeninfo);
			continue;
		}
		struct timespec sleep_time = {
			.tv_sec = 0,
			.tv_nsec = 16666667,
		};
		nanosleep(&sleep_time, NULL);
	}
}
