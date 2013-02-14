//
//  NRLogger.m
//  NRFoundation
//
//  Created by Nikolai Ruhe on 2013-02-07.
//  Copyright (c) 2013 Nikolai Ruhe. All rights reserved.
//

#import "NRLogger.h"
#import "NRBundle.h"
#import "NRDevice.h"
#import <unistd.h>
#import <sys/ioctl.h>
#import <sys/param.h>

#if TARGET_IPHONE_SIMULATOR
	#import <sys/conf.h>
#else
// I don't know why <sys/conf.h> is missing on the iPhoneOS.platform
// It's there on iPhoneSimulator.platform, though. We need it for D_DISK, only:
	#if ! defined(D_DISK)
		#define	D_DISK	2
	#endif
#endif


@implementation NRLogger
{
	int _stderrFileDescriptor;
	NSTimer *_logfileRotationTimer;
	NSTimeInterval _logfileRotationCheckInterval;
}

+ (instancetype)sharedLogger
{
	static NRLogger *sharedLogger;
	if (sharedLogger == nil)
		sharedLogger = [[self alloc] init];
	return sharedLogger;
}

- (id)init
{
	self = [super init];
	if (self) {
		_stderrFileDescriptor = -1;
	}
	return self;
}

- (void)dealloc
{
	self.logfileRotationCheckInterval = 0;
	self.redirectStderr = NO;
}

- (NSString *)logfileDirectory
{
	static NSString *logfileDirectory;
	if (logfileDirectory == nil) {
		logfileDirectory = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0];
		logfileDirectory = [logfileDirectory stringByAppendingPathComponent:@"Logs"];
		logfileDirectory = [logfileDirectory stringByAppendingPathComponent:@"AppConsole"];
		[[NSFileManager defaultManager] createDirectoryAtPath:logfileDirectory
								  withIntermediateDirectories:YES
												   attributes:nil
														error:NULL];
	}
	return logfileDirectory;
}

- (NSString *)filenamePrefix
{
	return @"Logfile_";
}

- (NSUInteger)minumNumberOfLogfilesToKeep
{
	// keep a minimum of 3 logfiles before removing any
	return 3;
}

- (NSUInteger)maximumNumberOfLogfilesToKeep
{
	// keep a maximum of 100 logfiles
	return 100;
}

- (unsigned long long)maximumIndividualLogfileSize
{
	// try to keep logfiles under around 1 MB
	return 1024LU * 1024LU * 1LU;
}

- (unsigned long long)maximumCombinedLogfileSize
{
	// keep a maximum of 2 MB
	return 1024LU * 1024LU * 2LU;
}

- (NSTimeInterval)logfileRotationCheckInterval
{
	@synchronized (self) {
		return _logfileRotationCheckInterval;
	}
}

- (void)setLogfileRotationCheckInterval:(NSTimeInterval)logfileRotationCheckInterval
{
	NSAssert([NSThread isMainThread], @"logfileRotationCheckInterval can only be modified from the main thread.");

	@synchronized (self) {

		if (_logfileRotationCheckInterval == logfileRotationCheckInterval)
			return;

		_logfileRotationCheckInterval = logfileRotationCheckInterval;

		if (_logfileRotationCheckInterval <= 0) {
			_logfileRotationCheckInterval = 0;
			[_logfileRotationTimer invalidate];
			_logfileRotationTimer = nil;
		}

		[_logfileRotationTimer invalidate];
		_logfileRotationTimer = [NSTimer scheduledTimerWithTimeInterval:_logfileRotationCheckInterval
																 target:self
															   selector:@selector(logfileRotationTimerFired:)
															   userInfo:nil
																repeats:YES];
	}
}

- (void)logfileRotationTimerFired:(NSTimer *)timer
{
	[self checkLogfileRotation];
}

- (NSArray *)allLogFileURLsOrderedByModificationDateReverse:(BOOL)reverse
{
	NSString *directory = [self logfileDirectory];
	NSArray *fileURLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory isDirectory:YES]
													  includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLContentModificationDateKey]
																		 options:NSDirectoryEnumerationSkipsHiddenFiles
																		   error:NULL];

	// filter proper logfiles
	NSMutableArray *files = [NSMutableArray array];
	for (NSURL *fileURL in fileURLs) {
		if (! [[fileURL lastPathComponent] hasPrefix:[self filenamePrefix]])
			continue;

		NSNumber *isFile;
		[fileURL getResourceValue:&isFile
						   forKey:NSURLIsRegularFileKey
							error:NULL];
		if (! [isFile boolValue])
			continue;

		[files addObject:fileURL];
	}

	// sort files by modification date
	[files sortUsingComparator:^NSComparisonResult(NSURL *file1, NSURL *file2) {
		NSDate *date1;
		[file1 getResourceValue:&date1
						 forKey:NSURLContentModificationDateKey
						  error:NULL];
		NSDate *date2;
		[file2 getResourceValue:&date2
						 forKey:NSURLContentModificationDateKey
						  error:NULL];
		return reverse ? [date2 compare:date1] : [date1 compare:date2];
	}];

	return files;
}

- (unsigned long long)removeOldLogfiles
{
	unsigned long long combinedSize = 0;
	NSUInteger logfileCount = 0;

	// iterate over existing logfiles, newest first
	for (NSURL *fileURL in [self allLogFileURLsOrderedByModificationDateReverse:YES]) {

		logfileCount += 1;

		BOOL canRemoveLogfiles    = logfileCount > [self minumNumberOfLogfilesToKeep];
		BOOL shouldRemoveLogfiles = combinedSize > [self maximumCombinedLogfileSize];
		BOOL mustRemoveLogfiles   = logfileCount > [self maximumNumberOfLogfilesToKeep];

		if ((canRemoveLogfiles && shouldRemoveLogfiles) || mustRemoveLogfiles) {
			NSLog(@"removing old logfile: %@", [fileURL lastPathComponent]);
			[[NSFileManager defaultManager] removeItemAtURL:fileURL
													  error:NULL];
		} else {
			NSNumber *fileSize;
			[fileURL getResourceValue:&fileSize
							   forKey:NSURLFileSizeKey
								error:NULL];

			combinedSize += [fileSize unsignedLongLongValue];
		}
	}

	return combinedSize;
}

- (NSString *)newLogFilename
{
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	[formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
	[formatter setLocale:nil];

	NSString *filename = [NSString stringWithFormat:@"%@%@.log", [self filenamePrefix], [formatter stringFromDate:[NSDate date]]];

	NSString *path = [[self logfileDirectory] stringByAppendingPathComponent:filename];

	return path;
}

- (void)checkLogfileRotation
{
	@synchronized (self) {

		// do we redirect at the moment?
		if (! self.redirectStderr)
			return;

		// STDERR_FILENO is the file descriptor of our logfile
		off_t offset = lseek(STDERR_FILENO, 0, SEEK_CUR);
		if (offset < 0)
			return;

		if (offset < (off_t)[self maximumIndividualLogfileSize])
			return;

		// create new logfile and remove old files
		[self redirectStderrIntoNewLogfile];
	}
}

- (void)logAppInfo
{
	NSLog(@"\n"
		  @"name=\"%@\"\n"
		  @"version=\"%@\"\n"
		  @"bundleIdentifier=\"%@\"\n"
		  @"path=\"%@\"\nUUID=\"%@\"\n"
		  @"device=\"%@\"\n"
		  @"model=\"%@\"\n"
		  @"modelID=\"%@\"\n"
		  @"MACAddress=\"%@\"\n"
		  @"OS=\"%@ %@\"\n\n",
		  [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"],
		  [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
		  [[NSBundle mainBundle] bundleIdentifier],
		  [[NSBundle mainBundle] executablePath],
		  [NSBundle executableLinkEditorUUID],
		  [UIDevice currentDevice].name,
		  [UIDevice currentDevice].model,
		  [UIDevice currentDevice].modelID,
		  [UIDevice currentDevice].MACAddress,
		  [UIDevice currentDevice].systemName,
		  [UIDevice currentDevice].systemVersion
		  );

}

- (BOOL)redirectStderr
{
	@synchronized (self) {
		return _stderrFileDescriptor >= 0;
	}
}

- (void)setRedirectStderr:(BOOL)redirectStderr
{
	if (self.redirectStderr == (_Bool)redirectStderr)
		return;

	if (redirectStderr) {
		[self startRedirectingStderr];
	} else {
		[self stopRedirectingStderr];
	}
}

- (void)startRedirectingStderr
{
	@synchronized (self) {

		if (self.redirectStderr)
			return;

		// make a copy of stderr
		_stderrFileDescriptor = dup(STDERR_FILENO);
		if (_stderrFileDescriptor < 0) {
			NSLog(@"could not dup stderr: %d", errno);
			return;
		}

		if (! [self redirectStderrIntoNewLogfile]) {
			close(_stderrFileDescriptor);
			_stderrFileDescriptor = -1;
		}
		//asl_add_log_file
	}
}

- (BOOL)redirectStderrIntoNewLogfile
{
	@synchronized (self) {

		NSString *path = [self newLogFilename];
		const char *logfilename = [[NSFileManager defaultManager] fileSystemRepresentationWithPath:path];

		int fd = open(logfilename, O_RDWR | O_CREAT | O_TRUNC, 0666);
		if (fd < 0) {
			NSLog(@"could not open logfile: %d", errno);
			return NO;
		}

		// duplicate the logfile's descriptor over stderr
		int result = dup2(fd, STDERR_FILENO);
		if (result < 0) {
			NSLog(@"could not duplicate logfile descriptor over stderr: %d", errno);
			close(fd);
			return NO;
		}

		// we don't need the original fd of the logfile any more.
		// It's now named stderr
		close(fd);

		// print message to original stderr
		dprintf(_stderrFileDescriptor, "redirecting stderr to \"%s\"\n", logfilename);

		dprintf(STDERR_FILENO,
				"--------------------------------------------------------------------------------\n"
				"%s\n"
				"--------------------------------------------------------------------------------\n",
				logfilename);

		[self removeOldLogfiles];

		return YES;
	}
}

- (void)stopRedirectingStderr
{
	@synchronized (self) {

		if (! self.redirectStderr)
			return;

		int result = dup2(_stderrFileDescriptor, STDERR_FILENO);
		if (result < 0) {
			NSLog(@"could not duplicate original stderr descriptor over stderr: %d", errno);
			return;
		}

		close(_stderrFileDescriptor);
		_stderrFileDescriptor = -1;

		// print message to original stderr
		dprintf(_stderrFileDescriptor, "stopped redirecting stderr\n");
	}
}

- (BOOL)writeLogFilesToPath:(NSString *)path
{
	if (! [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil]) {
		NSLog(@"could not create archive at path: %@", path);
		return NO;
	}

	NSFileHandle *outFile = [NSFileHandle fileHandleForWritingAtPath:path];
	if (outFile == nil) {
		NSLog(@"could not create file handle for writing at path: %@", path);
		return NO;
	}

	for (NSURL *fileURL in [self allLogFileURLsOrderedByModificationDateReverse:NO]) {
		@autoreleasepool {
			NSData *inData = [NSData dataWithContentsOfURL:fileURL
												   options:NSDataReadingMappedIfSafe
													 error:NULL];
			if (inData != nil) {
				[outFile writeData:inData];
				char message[] = "\n--- end of file ---\n\n";
				[outFile writeData:[NSData dataWithBytes:message length:sizeof(message) - 1]];
			}
		}
	}

	return YES;
}

- (BOOL)isDebuggerAttatchedToConsole
{
	// We use the type of the original stderr file descriptor
	// to guess if a debugger is attached.

	int fd = self.redirectStderr ? _stderrFileDescriptor : STDERR_FILENO;

	// is the file handle open?
	if (fcntl(fd, F_GETFD, 0) < 0) {
		return NO;
	}

	// get the path of stderr's file handle
	char buf[MAXPATHLEN + 1];
	if (fcntl(fd, F_GETPATH, buf ) >= 0) {
		if (strcmp(buf, "/dev/null") == 0)
			return NO;
		if (strncmp(buf, "/dev/tty", 8) == 0)
			return YES;
	}

	// On the device, without attached Xcode, the type is D_DISK (otherwise it's D_TTY)
	int type;
	if (ioctl(fd, FIODTYPE, &type) < 0) {
		return NO;
	}

	return type != D_DISK;
}

@end


#if defined(NR_LOGGER_AUTOSTART) && NR_LOGGER_AUTOSTART
static void autostart(void) __attribute__((constructor));
static void autostart(void)
{
	if ([NRLogger sharedLogger].debuggerAttatchedToConsole) {
		[NRLogger sharedLogger].redirectStderr = YES;
	}

	[[NRLogger sharedLogger] logAppInfo];
}
#endif