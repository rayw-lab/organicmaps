#import <XCTest/XCTest.h>

#import "MWMLocationObserver.h"
#import "MWMRouter.h"
#import "MWMRoutingManager.h"
#import "MWMTextToSpeech.h"
#import "MapViewController.h"

#include <CoreApi/Framework.h>

#include "routing/route.hpp"
#include "routing/routing_options.hpp"

#include "geometry/mercator.hpp"

#include "base/scope_guard.hpp"

#import <objc/runtime.h>

#include <string>
#include <utility>
#include <vector>

@interface MWMRouter (SpeechOwnershipTests)
+ (MWMRouter *)router;
+ (void)enterTrackNavigation;
@end

@interface MWMSpeechLocationListener : NSObject <MWMRoutingManagerListener>
@property(nonatomic, copy) void (^onLocation)(void);
@end

@implementation MWMSpeechLocationListener
- (void)processRouteBuilderEventWithCode:(MWMRouterResultCode)code countries:(NSArray<NSString *> *)countries
{}
- (void)updateCameraInfo:(BOOL)isCameraOnRoute speedLimitMps:(double)limit
{}
- (void)didLocationUpdate
{
  if (self.onLocation)
    self.onLocation();
}
@end

@interface MWMRoutingSpeechOwnershipTests : XCTestCase
{
  bool m_notificationsEnabled;
  std::string m_locale;
}
@end

@implementation MWMRoutingSpeechOwnershipTests
- (void)setUp
{
  [super setUp];
  [[MapViewController sharedController] loadViewIfNeeded];
  auto & manager = GetFramework().GetRoutingManager();
  m_notificationsEnabled = manager.AreTurnNotificationsEnabled();
  m_locale = manager.GetTurnNotificationsLocale();
  manager.CloseRouting(true);
}

- (void)tearDown
{
  auto & manager = GetFramework().GetRoutingManager();
  manager.CloseRouting(true);
  manager.RoutingSession().SetRoutingSettings(routing::GetRoutingSettings(
      routing::RoutingOptions::GetVehicleType(manager.GetRouter()).value_or(routing::VehicleType::Transit)));
  manager.EnableTurnNotifications(m_notificationsEnabled);
  manager.SetTurnNotificationsLocale(m_locale);
  [super tearDown];
}

- (void)prepareApproach
{
  auto & manager = GetFramework().GetRoutingManager();
  manager.RoutingSession().Reset();
  auto const entry = mercator::FromLatLon(45.0, 19.0);
  auto const finish = mercator::FromLatLon(45.01, 19.0);
  auto const start = mercator::FromLatLon(44.998, 19.0);
  double const approach = mercator::DistanceOnEarth(start, entry);
  double const total = approach + mercator::DistanceOnEarth(entry, finish);
  routing::Segment const fake(routing::kFakeNumMwmId, 0, 0, false);
  std::vector<routing::RouteSegment> segments;
  segments.emplace_back(fake, routing::turns::TurnItem(1, routing::turns::PedestrianDirection::None),
                        geometry::PointWithAltitude(entry, 100), routing::RouteSegment::RoadNameInfo{});
  segments.emplace_back(fake, routing::turns::TurnItem(2, routing::turns::PedestrianDirection::ReachedYourDestination),
                        geometry::PointWithAltitude(finish, 110), routing::RouteSegment::RoadNameInfo{});
  segments[0].SetDistancesAndTime(approach, (entry - start).Length(), approach);
  segments[1].SetDistancesAndTime(total, (entry - start).Length() + (finish - entry).Length(), total);
  routing::Route route;
  route.SetRouteSegments(std::move(segments));
  route.SetSubroutes(std::vector<routing::Route::SubrouteAttrs>{
      {geometry::PointWithAltitude(start, 100), geometry::PointWithAltitude(finish, 110), 0, 2}});
  std::vector<m2::PointD> const points = {start, entry, finish};
  route.SetGeometry(points.begin(), points.end());
  route.SetTrackStartDistanceMeters(approach);
  manager.RoutingSession().SetRoutingSettings(routing::GetRoutingSettings(routing::VehicleType::Pedestrian));
  manager.SetTurnNotificationsLocale("en");
  manager.EnableTurnNotifications(true);
  manager.RoutingSession().AssignRouteForTesting(std::move(route), routing::RouterResultCode::NoError);
  XCTAssertTrue(manager.RoutingSession().EnableFollowMode());
}

- (void)testStartingAtTheEntryLeavesTheFirstTurnForGps
{
  [MWMTextToSpeech tts];
  [MWMRouter hideNavigationMapControls];
  auto & manager = GetFramework().GetRoutingManager();
  auto const start = mercator::FromLatLon(45.0, 19.0);
  auto const bend = mercator::FromLatLon(45.0018, 19.0);
  auto const finish = mercator::FromLatLon(45.0018, 19.01);
  double const toBend = mercator::DistanceOnEarth(start, bend);
  double const total = toBend + mercator::DistanceOnEarth(bend, finish);
  routing::Segment const fake(routing::kFakeNumMwmId, 0, 0, false);
  std::vector<routing::RouteSegment> segments;
  segments.emplace_back(fake, routing::turns::TurnItem(1, routing::turns::PedestrianDirection::TurnRight),
                        geometry::PointWithAltitude(bend, 100), routing::RouteSegment::RoadNameInfo{});
  segments.emplace_back(fake, routing::turns::TurnItem(2, routing::turns::PedestrianDirection::ReachedYourDestination),
                        geometry::PointWithAltitude(finish, 100), routing::RouteSegment::RoadNameInfo{});
  segments[0].SetDistancesAndTime(toBend, (bend - start).Length(), toBend);
  segments[1].SetDistancesAndTime(total, (bend - start).Length() + (finish - bend).Length(), total);
  routing::Route route;
  route.SetRouteSegments(std::move(segments));
  route.SetSubroutes(std::vector<routing::Route::SubrouteAttrs>{
      {geometry::PointWithAltitude(start, 100), geometry::PointWithAltitude(finish, 100), 0, 2}});
  std::vector<m2::PointD> const points = {start, bend, finish};
  route.SetGeometry(points.begin(), points.end());
  route.SetTrackStartDistanceMeters(0.0);
  manager.RoutingSession().SetRoutingSettings(routing::GetRoutingSettings(routing::VehicleType::Pedestrian));
  manager.SetTurnNotificationsLocale("en");
  manager.EnableTurnNotifications(true);
  manager.RoutingSession().AssignRouteForTesting(std::move(route), routing::RouterResultCode::NoError);
  XCTAssertTrue(manager.RoutingSession().EnableFollowMode());

  Method const poll = class_getClassMethod(MWMRouter.class, @selector(turnNotifications));
  IMP const originalPoll = method_getImplementation(poll);
  __block NSUInteger generalPolls = 0;
  IMP const replacementPoll = imp_implementationWithBlock(^NSArray<NSString *> *(id self) {
    ++generalPolls;
    return reinterpret_cast<NSArray<NSString *> * (*)(id, SEL)>(originalPoll)(self, @selector(turnNotifications));
  });
  method_setImplementation(poll, replacementPoll);
  SCOPE_GUARD(restorePoll, [&]
  {
    method_setImplementation(poll, originalPoll);
    imp_removeBlock(replacementPoll);
  });

  [MWMRouter enterTrackNavigation];

  XCTAssertEqual(generalPolls, 0U, @"Start may consume Approach, but must not poll ordinary maneuvers");
  XCTAssertGreaterThan([MWMRouter turnNotifications].count, 0U,
                       @"Start must leave the first maneuver pending until a navigation GPS update");
  [MWMRouter hideNavigationMapControls];
}

- (void)testTrackStartConsumesApproachOnceIncludingWhileMuted
{
  [MWMTextToSpeech tts];
  Method const active = class_getInstanceMethod(MWMTextToSpeech.class, @selector(active));
  Method const play = class_getInstanceMethod(MWMTextToSpeech.class, @selector(playTurnNotifications:));
  __block BOOL enabled = YES;
  auto played = [NSMutableArray<NSString *> array];
  IMP const activeReplacement = imp_implementationWithBlock(^BOOL(id self) { return enabled; });
  IMP const playReplacement = imp_implementationWithBlock(
      ^(id self, NSArray<NSString *> * notifications) { [played addObjectsFromArray:notifications]; });
  IMP const originalActive = method_setImplementation(active, activeReplacement);
  IMP const originalPlay = method_setImplementation(play, playReplacement);
  SCOPE_GUARD(restoreSpeech, [&]
  {
    method_setImplementation(active, originalActive);
    method_setImplementation(play, originalPlay);
    imp_removeBlock(activeReplacement);
    imp_removeBlock(playReplacement);
    [MWMRouter hideNavigationMapControls];
  });
  for (BOOL const muted : {NO, YES})
  {
    enabled = !muted;
    [played removeAllObjects];
    [MWMRouter hideNavigationMapControls];
    [self prepareApproach];
    [MWMRouter enterTrackNavigation];
    [MWMRouter enterTrackNavigation];
    XCTAssertEqualObjects(played, muted ? @[] : @[@"Proceed to the track."]);
    XCTAssertEqual([MWMRouter turnNotifications].count, 0U);
  }
}

- (void)notifyProxy
{
  auto location = [[CLLocation alloc] initWithLatitude:44.998 longitude:19.0];
  [(id<MWMLocationObserver>)[MWMRoutingManager routingManager] onLocationUpdate:location];
}

- (void)testPassiveProxyLeavesPhoneSpeechPending
{
  auto proxy = [MWMRoutingManager routingManager];
  for (bool const withListener : {false, true})
  {
    [self prepareApproach];
    auto listener = [[MWMSpeechLocationListener alloc] init];
    __block NSUInteger updates = 0;
    listener.onLocation = ^{ ++updates; };
    if (withListener)
      [proxy addListener:listener];
    SCOPE_GUARD(removeListener, [&]
    {
      if (withListener)
        [proxy removeListener:listener];
    });

    [self notifyProxy];

    XCTAssertEqual(updates, withListener ? 1U : 0U);
    XCTAssertEqualObjects([MWMRouter turnNotifications], (@[@"Proceed to the track."]));
    XCTAssertEqual([MWMRouter turnNotifications].count, 0U);
  }
}

- (void)testActiveConsumerPollsSpeechOnceFromLocationUpdates
{
  [self prepareApproach];
  auto proxy = [MWMRoutingManager routingManager];
  auto listener = [[MWMSpeechLocationListener alloc] init];
  auto received = [NSMutableArray<NSString *> array];
  listener.onLocation = ^{ [received addObjectsFromArray:[MWMRouter turnNotifications]]; };
  [proxy addListener:listener];
  SCOPE_GUARD(removeListener, [&] { [proxy removeListener:listener]; });

  [self notifyProxy];
  [self notifyProxy];

  XCTAssertEqualObjects(received, (@[@"Proceed to the track."]));
}

- (void)testPhoneOwnerConsumesItsPendingGuidance
{
  [MWMTextToSpeech tts];
  [self prepareApproach];
  auto location = [[CLLocation alloc] initWithLatitude:44.998 longitude:19.0];
  [(id<MWMLocationObserver>)[MWMRouter router] onLocationUpdate:location];
  XCTAssertEqual([MWMRouter turnNotifications].count, 0U);
}

- (void)testLatePhoneCallbackLeavesCarSpeechPending
{
  [self prepareApproach];
  Method const getter =
      class_getInstanceMethod(NSClassFromString(@"MWMCarPlayService"), NSSelectorFromString(@"isCarPlayRoutingActive"));
  XCTAssertTrue(getter != nullptr);
  if (getter == nullptr)
    return;
  IMP const replacement = imp_implementationWithBlock(^BOOL(id self) { return YES; });
  IMP const original = method_setImplementation(getter, replacement);
  SCOPE_GUARD(restoreGetter, [&]
  {
    method_setImplementation(getter, original);
    imp_removeBlock(replacement);
  });

  auto location = [[CLLocation alloc] initWithLatitude:44.998 longitude:19.0];
  [(id<MWMLocationObserver>)[MWMRouter router] onLocationUpdate:location];

  XCTAssertEqualObjects([MWMRouter turnNotifications], (@[@"Proceed to the track."]));
}
@end
