//
//  TUCTouch.m
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#import "TUCTouch.h"


@implementation TUCGestureContext

- (instancetype)initWithSurface:(TUCSurfaceKind)surface
                         source:(TUCSurfaceSource)source
                          state:(TUCSurfaceState)state
                  digitizerKind:(TUCDigitizerKind)digitizerKind
                     locationID:(uint32_t)locationID
                 screenLocation:(CGPoint)screenLocation
                        didHold:(BOOL)didHold {
    if (self = [super init]) {
        _surface = surface;
        _surfaceSource = source;
        _surfaceState = state;
        _digitizerKind = digitizerKind;
        _locationID = locationID;
        _screenLocation = screenLocation;
        _didHold = didHold;
    }
    return self;
}

@end


@implementation TUCTouch

- (instancetype)initWithContactID:(NSInteger)contactID locationID:(uint32_t)locationID {
    if (self = [super init]) {
        
        _uuid = [NSUUID UUID];

        // Monotone for the life of the process. Only ever compared for equality and
        // ordering, so wrapping after a few quintillion fingers is not a concern.
        static NSUInteger nextIdentity = 1;
        _identity = nextIdentity++;

        _removalGeneration = 0;
        _previousContactID = NSNotFound;
        _timesResumed = 0;
        
        _contactID = contactID;
        _locationID = locationID;
        
        _location = CGPointZero;
        
        _isOnSurface = true;
        _isConfidentFinger = true;
        
        _size = CGSizeZero;
        _azimuth = 0;
        
        
        _lastUpdated = 0;
        _lastUpdatedTime = [NSDate timeIntervalSinceReferenceDate];
        
        
        _phase = NSTouchPhaseBegan;
        _previousPhase = NSTouchPhaseBegan;
        
        _location = CGPointZero;
        _previousLocation = CGPointZero;
    }
    return self;
}




@synthesize phase = _phase;

- (NSTouchPhase)phase {
    return _phase;
}

- (void)invalidatePendingRemoval {
    _removalGeneration++;
}


- (void)resumeUnderContactID:(NSInteger)contactID {
    _previousContactID = _contactID;
    _contactID = contactID;
    _timesResumed++;

    // Any removal already scheduled belonged to the touch's previous life.
    _removalGeneration++;

    // Written straight to the ivars, deliberately. Going through `-setPhase:` would push
    // the old phase into `_previousPhase`, and a `_previousPhase` of `Ended` makes the
    // input manager skip both the phase classification and the tap-and-hold update for a
    // whole report — the finger would be back but nothing would be watching it.
    //
    // `Stationary` is the honest placeholder: the finger is down, and what it is doing is
    // recomputed from its real movement two lines after this returns.
    _phase = NSTouchPhaseStationary;
    _previousPhase = NSTouchPhaseStationary;

    // `_location`, `_previousLocation`, `_lastUpdated`, `_lastUpdatedTime`, `_uuid` and
    // `_identity` are all left exactly as they are. The step across the gap is real finger
    // movement and the code downstream is entitled to see it.
}


- (void)setPhase:(NSTouchPhase)phase {
    _previousPhase = _phase;
    _phase = phase;
}


@synthesize location = _location;

- (CGPoint)location {
    return _location;
}

- (void)setLocation:(CGPoint)location {
    _previousLocation = _location;
    _location = location;
}



#pragma mark - Gesture Detection


- (CGPoint)trajectory {
    CGPoint p1 = [self location];
    CGPoint p2 = [self previousLocation];
    return CGPointMake(p1.x - p2.x,
                       p1.y - p2.y);
}

- (CGPoint)trajectorySign {
    CGPoint p = [self trajectory];
    return CGPointMake(p.x < 0 ? -1 : p.x > 0 ? 1 : 0,
                       p.y < 0 ? -1 : p.y > 0 ? 1 : 0);
}


#pragma mark - Utility
- (BOOL)isActive {
    return _phase != NSTouchPhaseEnded && _phase != NSTouchPhaseCancelled;
}


- (NSComparisonResult) compareWithAnotherTouch:(TUCTouch*) anotherTouch {
    return [[NSNumber numberWithInteger:self.contactID] compare:[NSNumber numberWithInteger:anotherTouch.contactID]];
}


- (NSString *)debugDescription {
    NSString *phase;
    if (self.phase == NSTouchPhaseBegan) {
        phase = @"Began";
    } else if (self.phase == NSTouchPhaseMoved) {
        phase = @"Moved";
    } else if (self.phase == NSTouchPhaseStationary) {
        phase = @"Stationary";
    } else if (self.phase == NSTouchPhaseEnded) {
        phase = @"Ended";
    } else if (self.phase == NSTouchPhaseCancelled) {
        phase = @"Cancelled";
    } else {
        phase = [NSString stringWithFormat:@"Phase %ld", self.phase];
    }
    
    return [NSString stringWithFormat:@"Touch %ld: Location: %@ Phase:%@  OnSurface:%@", self.contactID, NSStringFromPoint(self.location), phase, [NSNumber numberWithBool:self.isOnSurface]];
}

@end
