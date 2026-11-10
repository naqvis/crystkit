require "http/headers"
require "./spec_helper"
require "../src/features/positioning"

class TestPositioner < CrystKit::Features::WindowPositioner
  def initialize
    @screen_change_handler = nil
  end

  protected def platform_screen_list : Array(CrystKit::Features::ScreenInfo)
    bounds = CrystKit::Features::Rectangle.new(0, 0, 1920, 1080)
    work_area = CrystKit::Features::Rectangle.new(0, 0, 1920, 1040)
    [
      CrystKit::Features::ScreenInfo.new(bounds, work_area, 0),
    ]
  end

  protected def cursor_position : CrystKit::Features::Point
    CrystKit::Features::Point.new(960, 540)
  end
end

describe CrystKit::Features::WindowPositioner do
  it "display_count returns 1 for test screen config" do
    p = TestPositioner.new
    p.display_count.should eq(1)
  end
  it "screen_info returns primary display" do
    p = TestPositioner.new
    info = p.screen_info
    info.bounds.width.should eq(1920)
    info.bounds.height.should eq(1080)
    info.work_area.height.should eq(1040)
  end
  it "position_at_corner places at top-left" do
    p = TestPositioner.new
    pt = p.position_at_corner(CrystKit::Features::Rectangle.new(0, 0, 400, 300), CrystKit::Features::Corner::TopLeft)
    pt.x.should eq(0)
    pt.y.should eq(0)
  end
  it "position_at_corner places at bottom-right" do
    p = TestPositioner.new
    pt = p.position_at_corner(CrystKit::Features::Rectangle.new(0, 0, 400, 300), CrystKit::Features::Corner::BottomRight)
    pt.x.should eq(1520)
    pt.y.should eq(740)
  end
  it "position_at_edge centers on left edge" do
    p = TestPositioner.new
    pt = p.position_at_edge(CrystKit::Features::Rectangle.new(0, 0, 200, 100), CrystKit::Features::Edge::Left)
    pt.x.should eq(0)
    pt.y.should eq(470)
  end
  it "position_at_edge centers on screen center" do
    p = TestPositioner.new
    pt = p.position_at_edge(CrystKit::Features::Rectangle.new(0, 0, 200, 100), CrystKit::Features::Edge::Center)
    pt.x.should eq(860)
    pt.y.should eq(470)
  end
  it "ensure_on_screen clamps to work area" do
    p = TestPositioner.new
    pt = p.ensure_on_screen(CrystKit::Features::Point.new(-50, -50), CrystKit::Features::Rectangle.new(0, 0, 2000, 1200))
    pt.x.should eq(0)
    pt.y.should eq(0)
  end
  it "position_at_tray raises on zero-size rect" do
    p = TestPositioner.new
    expect_raises(CrystKit::Core::Error, /positive/) do
      p.position_at_tray(CrystKit::Features::Rectangle.new(0, 0, 200, 100), CrystKit::Features::Rectangle.new(0, 0, 0, 0))
    end
  end
  it "position_at_cursor returns a point" do
    p = TestPositioner.new
    pt = p.position_at_cursor(CrystKit::Features::Rectangle.new(0, 0, 200, 100))
    pt.x.should eq(968)
    pt.y.should eq(548)
  end
  it "snap to left returns correct bounds" do
    p = TestPositioner.new
    snap_info = p.screen_info
    wa = snap_info.work_area
    snap_left = CrystKit::Features::Rectangle.new(wa.x, wa.y, wa.width // 2, wa.height)
    snap_left.width.should eq(960)
    snap_left.height.should eq(1040)
  end
  it "snap to top-right returns correct bounds" do
    p = TestPositioner.new
    snap_info = p.screen_info
    wa = snap_info.work_area
    snap_tr = CrystKit::Features::Rectangle.new(
      wa.x + wa.width // 2, wa.y,
      wa.width // 2, wa.height // 2
    )
    snap_tr.x.should eq(960)
    snap_tr.y.should eq(0)
    snap_tr.width.should eq(960)
    snap_tr.height.should eq(520)
  end
  it "tile horizontal divides width equally" do
    p = TestPositioner.new
    info = p.screen_info
    seg_w = info.work_area.width // 3
    seg_w.should eq(640)
  end
  it "tile vertical divides height equally" do
    p = TestPositioner.new
    info = p.screen_info
    seg_h = info.work_area.height // 2
    seg_h.should eq(520)
  end
  it "on_screen_change registers handler" do
    p = TestPositioner.new
    called = false
    p.on_screen_change { called = true }
    p.notify_screen_change
    called.should be_true
  end
end
