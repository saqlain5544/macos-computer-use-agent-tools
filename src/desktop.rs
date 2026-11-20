//! The dashboard.
//!
//! This is a readout, not a simulator: the agent works in the real app on the
//! real desktop, and this window shows what it is bound to, what it just did,
//! and the focus-guard counters. The control loop lives on the server threads,
//! so this window can be minimised, hidden, or on another Space and the agent
//! keeps working.

use egui::{Align2, Color32, FontId, Pos2, Rect, Sense, Stroke, Vec2};

use crate::helper::{Node, Point};
use crate::session::{Handle, Mode, Shared};

fn col(r: u8, g: u8, b: u8) -> Color32 {
    Color32::from_rgb(r, g, b)
}

fn alpha(r: u8, g: u8, b: u8, a: u8) -> Color32 {
    Color32::from_rgba_unmultiplied(r, g, b, a)
}

const BG: (u8, u8, u8) = (13, 19, 31);
const PANEL: (u8, u8, u8) = (20, 29, 45);
const TEXT: (u8, u8, u8) = (214, 226, 242);
const DIM: (u8, u8, u8) = (130, 154, 184);
const GREEN: (u8, u8, u8) = (120, 231, 196);
const AMBER: (u8, u8, u8) = (255, 193, 102);
const RED: (u8, u8, u8) = (255, 122, 116);
const BLUE: (u8, u8, u8) = (110, 168, 254);

fn vec2(x: f32, y: f32) -> Vec2 {
    Vec2::new(x, y)
}

pub fn truncate(s: &str, n: usize) -> String {
    let one: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() <= n {
        one
    } else {
        let t: String = one.chars().take(n.saturating_sub(1)).collect();
        format!("{}…", t)
    }
}

fn heading(ui: &mut egui::Ui, text: &str) {
    ui.add_space(8.0);
    ui.add(
        egui::Label::new(egui::RichText::new(text).size(10.5).strong().color(col(130, 158, 190)))
            .selectable(false),
    );
    ui.add_space(3.0);
}

fn pill(ui: &mut egui::Ui, text: &str, color: Color32) {
    let (rect, _) = ui.allocate_exact_size(vec2(text.len() as f32 * 7.4 + 22.0, 22.0), Sense::hover());
    ui.painter().rect_filled(rect, 11.0, alpha(color.r(), color.g(), color.b(), 40));
    ui.painter().rect_stroke(
        rect,
        11.0,
        Stroke::new(1.0, alpha(color.r(), color.g(), color.b(), 190)),
        egui::StrokeKind::Outside,
    );
    ui.painter().text(rect.center(), Align2::CENTER_CENTER, text, FontId::proportional(10.5), color);
}

fn mono(ui: &mut egui::Ui, text: &str, size: f32, color: Color32) {
    ui.add(
        egui::Label::new(egui::RichText::new(text).monospace().size(size).color(color))
            .selectable(false)
            .wrap_mode(egui::TextWrapMode::Truncate),
    );
}

fn lab(ui: &mut egui::Ui, text: &str, size: f32, color: Color32) {
    ui.add(
        egui::Label::new(egui::RichText::new(text).size(size).color(color))
            .selectable(false)
            .wrap_mode(egui::TextWrapMode::Truncate),
    );
}

pub fn draw(ui: &mut egui::Ui, shared: &Handle, fps: f32) {
    ui.painter().rect_filled(ui.max_rect(), 0.0, col(BG.0, BG.1, BG.2));
    let margin = egui::Margin { left: 16, right: 16, top: 10, bottom: 8 };
    egui::Frame::new().inner_margin(margin).show(ui, |ui| {
        let mut s = shared.lock().unwrap();
        content(ui, &mut s, fps);
    });
}

fn content(ui: &mut egui::Ui, s: &mut Shared, fps: f32) {
    ui.horizontal(|ui| {
        ui.add(
            egui::Label::new(
                egui::RichText::new("QUIET DRIVER").size(17.0).strong().color(col(232, 241, 252)),
            )
            .selectable(false),
        );
        ui.add_space(6.0);
        lab(ui, "background computer use · your desktop stays yours", 11.0, col(DIM.0, DIM.1, DIM.2));
        ui.add_space(10.0);
        pill(
            ui,
            if !s.running {
                "PAUSED"
            } else if s.target.is_some() {
                "BOUND"
            } else {
                "IDLE"
            },
            if !s.running {
                col(AMBER.0, AMBER.1, AMBER.2)
            } else if s.target.is_some() {
                col(GREEN.0, GREEN.1, GREEN.2)
            } else {
                col(DIM.0, DIM.1, DIM.2)
            },
        );
        ui.add_space(6.0);
        pill(
            ui,
            if s.mode == Mode::Focused { "FOCUSED" } else { "BACKGROUND" },
            if s.mode == Mode::Focused {
                col(AMBER.0, AMBER.1, AMBER.2)
            } else {
                col(BLUE.0, BLUE.1, BLUE.2)
            },
        );

        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            mono(ui, &format!("{} fps", fps.round() as u32), 12.0, col(GREEN.0, GREEN.1, GREEN.2));
            ui.add_space(8.0);
            if ui
                .button(if s.mode == Mode::Focused { "Focused mode" } else { "Background mode" })
                .clicked()
            {
                s.mode = if s.mode == Mode::Focused { Mode::Background } else { Mode::Focused };
            }
            if ui.button(if s.running { "Pause" } else { "Resume" }).clicked() {
                s.running = !s.running;
            }
        });
    });
    ui.add_space(6.0);
    ui.separator();
    ui.add_space(8.0);

    let row_height = (ui.available_size().y - 40.0).max(200.0);
    let row_width = ui.available_size().x;
    ui.horizontal(|ui| {
        ui.allocate_ui_with_layout(vec2(300.0, row_height), egui::Layout::top_down(egui::Align::LEFT), |ui| {
            sidebar(ui, s)
        });
        ui.add_space(8.0);
        ui.separator();
        ui.add_space(10.0);
        let canvas_width = (row_width - 330.0).max(160.0);
        let (rect, _) = ui.allocate_exact_size(vec2(canvas_width, row_height), Sense::hover());
        main_panel(ui.painter(), rect, s);
    });

    ui.add_space(6.0);
    ui.separator();
    lab(
        ui,
        "Actions go straight to the bound app through Accessibility or CGEventPostToPid · no pointer moves · no focus stealing",
        10.5,
        col(125, 150, 180),
    );
}

fn sidebar(ui: &mut egui::Ui, s: &mut Shared) {
    heading(ui, "TARGET");
    match &s.target {
        Some(t) => {
            lab(ui, &t.app_name, 14.0, col(TEXT.0, TEXT.1, TEXT.2));
            if !t.window_title.is_empty() {
                mono(ui, &t.window_title, 10.5, col(DIM.0, DIM.1, DIM.2));
            }
            mono(
                ui,
                &format!("pid {} · window {} · {:.0}x{:.0}", t.pid, t.window_id, t.bounds.w, t.bounds.h),
                10.0,
                col(BLUE.0, BLUE.1, BLUE.2),
            );
        }
        None => {
            lab(ui, "no app bound", 12.5, col(AMBER.0, AMBER.1, AMBER.2));
            mono(ui, "bind_app {\"app\":\"Calculator\"}", 10.0, col(DIM.0, DIM.1, DIM.2));
        }
    }

    heading(ui, "FOCUS GUARD");
    let ok = col(GREEN.0, GREEN.1, GREEN.2);
    ui.add(
        egui::Label::new(egui::RichText::new("✓  Your pointer stays yours").size(11.0).color(ok))
            .selectable(false),
    );
    mono(
        ui,
        &format!("   cursor {:.0}, {:.0}", s.agent_cursor.x, s.agent_cursor.y),
        10.0,
        col(DIM.0, DIM.1, DIM.2),
    );
    ui.add(
        egui::Label::new(
            egui::RichText::new(format!(
                "{}  focus changes by the driver",
                if s.focus_events == 0 { "✓" } else { "!" }
            ))
            .size(11.0)
            .color(if s.focus_events == 0 { ok } else { col(AMBER.0, AMBER.1, AMBER.2) }),
        )
        .selectable(false),
    );
    mono(
        ui,
        &format!("   frontmost: {}", if s.frontmost.is_empty() { "<unknown>" } else { s.frontmost.as_str() }),
        10.0,
        col(DIM.0, DIM.1, DIM.2),
    );

    heading(ui, "PERMISSIONS");
    let perm = |ui: &mut egui::Ui, granted: bool, what: &str| {
        ui.add(
            egui::Label::new(
                egui::RichText::new(format!("{}  {}", if granted { "✓" } else { "✗" }, what))
                    .size(10.5)
                    .color(if granted { ok } else { col(RED.0, RED.1, RED.2) }),
            )
            .selectable(false),
        );
    };
    perm(ui, s.permissions.accessibility, "Accessibility");
    perm(ui, s.permissions.post_events, "Post events");
    perm(ui, s.permissions.screen_capture, "Screen recording");

    heading(ui, "LOCAL LINK");
    mono(ui, &format!("127.0.0.1:{}", s.port), 11.0, col(BLUE.0, BLUE.1, BLUE.2));
    mono(ui, "health · status · windows · tree · action", 9.8, col(120, 140, 168));

    heading(ui, "LIVE ACTIONS");
    let recent = s.recent(8);
    if recent.is_empty() {
        mono(ui, "waiting for the first action…", 9.8, col(110, 130, 155));
    }
    for entry in recent.iter().rev() {
        let color = if entry.ok { col(150, 176, 205) } else { col(RED.0, RED.1, RED.2) };
        mono(
            ui,
            &format!(
                "{}{} {}",
                if entry.focus_changed { "⇄ " } else { "" },
                entry.tool,
                truncate(&entry.detail, 60)
            ),
            9.8,
            color,
        );
    }
}

fn main_panel(p: &egui::Painter, rect: Rect, s: &Shared) {
    if rect.width() < 60.0 || rect.height() < 60.0 {
        return;
    }
    p.rect_filled(rect, 10.0, col(PANEL.0, PANEL.1, PANEL.2));
    p.rect_stroke(
        rect,
        10.0,
        Stroke::new(1.0, alpha(110, 140, 180, 70)),
        egui::StrokeKind::Inside,
    );

    let inner = rect.shrink(14.0);
    p.text(
        Pos2::new(inner.left(), inner.top()),
        Align2::LEFT_TOP,
        "BOUND WINDOW",
        FontId::proportional(10.5),
        alpha(DIM.0, DIM.1, DIM.2, 220),
    );

    let Some(t) = &s.target else {
        p.text(
            inner.center(),
            Align2::CENTER_CENTER,
            "No app bound.\nPOST /action { \"tool\": \"bind_app\", \"app\": \"Calculator\" }",
            FontId::proportional(13.0),
            alpha(DIM.0, DIM.1, DIM.2, 230),
        );
        return;
    };

    let top = inner.top() + 26.0;
    let avail_h = (inner.bottom() - top - 54.0).max(40.0);
    let avail_w = inner.width();
    let win_w = t.bounds.w.max(1.0);
    let win_h = t.bounds.h.max(1.0);
    let scale = (avail_w / win_w as f32).min(avail_h / win_h as f32).max(0.01);
    let size = vec2(win_w as f32 * scale, win_h as f32 * scale);
    let origin = Pos2::new(
        inner.left() + (avail_w - size.x) * 0.5,
        top + (avail_h - size.y) * 0.5,
    );
    let screen = Rect::from_min_size(origin, size);
    p.rect_filled(screen.translate(vec2(6.0, 8.0)), 8.0, alpha(0, 0, 0, 90));
    p.rect_filled(screen, 8.0, col(26, 36, 56));
    p.rect_stroke(
        screen,
        8.0,
        Stroke::new(1.3, alpha(BLUE.0, BLUE.1, BLUE.2, 160)),
        egui::StrokeKind::Outside,
    );

    let bar = Rect::from_min_size(screen.min, vec2(screen.width(), 24.0));
    p.rect_filled(bar, 8.0, col(20, 29, 45));
    for (i, dot) in [RED, AMBER, GREEN].iter().enumerate() {
        p.circle_filled(
            Pos2::new(screen.left() + 14.0 + i as f32 * 13.0, bar.center().y),
            3.2,
            col(dot.0, dot.1, dot.2),
        );
    }
    p.text(
        Pos2::new(screen.left() + 54.0, bar.top() + 4.0),
        Align2::LEFT_TOP,
        if t.window_title.is_empty() { t.app_name.as_str() } else { t.window_title.as_str() },
        FontId::proportional(11.0),
        col(TEXT.0, TEXT.1, TEXT.2),
    );

    // Real accessibility nodes, re-based into window coordinates, as faint
    // boxes. This is a picture of the app the agent is actually driving.
    for node in s.tree.iter().take(400) {
        if node.frame.w <= 0.0 || node.frame.h <= 0.0 {
            continue;
        }
        if !matches!(
            node.role.as_str(),
            "AXButton" | "AXTextField" | "AXTextArea" | "AXStaticText" | "AXCheckBox" | "AXMenuButton"
                | "AXPopUpButton" | "AXRadioButton" | "AXScrollArea"
        ) {
            continue;
        }
        let x = origin.x + (node.frame.x - t.bounds.x) as f32 * scale;
        let y = origin.y + (node.frame.y - t.bounds.y) as f32 * scale;
        let w = (node.frame.w as f32 * scale).max(1.5);
        let h = (node.frame.h as f32 * scale).max(1.5);
        let box_ = Rect::from_min_size(Pos2::new(x, y), vec2(w, h));
        if box_.is_negative() || !screen.shrink(1.0).intersects(box_) {
            continue;
        }
        let fill = match node.role.as_str() {
            "AXTextArea" | "AXTextField" => alpha(GREEN.0, GREEN.1, GREEN.2, 46),
            "AXStaticText" => alpha(150, 175, 205, 26),
            "AXScrollArea" => alpha(90, 120, 160, 18),
            _ => alpha(BLUE.0, BLUE.1, BLUE.2, 38),
        };
        p.rect_filled(box_, 2.5, fill);
    }

    let c = Pos2::new(
        origin.x + s.agent_cursor.x as f32 * scale,
        origin.y + s.agent_cursor.y as f32 * scale,
    );
    p.circle_filled(c, 6.0, alpha(10, 18, 32, 220));
    p.circle_stroke(c, 6.0, Stroke::new(1.6, col(255, 255, 255)));
    p.circle_filled(c, 2.4, col(255, 255, 255));

    let base = inner.bottom() - 46.0;
    p.text(
        Pos2::new(inner.left(), base),
        Align2::LEFT_TOP,
        format!(
            "mode {} · frontmost {} · focus changes {}",
            s.mode.as_str(),
            if s.frontmost.is_empty() { "<unknown>" } else { s.frontmost.as_str() },
            s.focus_events
        ),
        FontId::monospace(10.5),
        col(DIM.0, DIM.1, DIM.2),
    );
    p.text(
        Pos2::new(inner.left(), base + 16.0),
        Align2::LEFT_TOP,
        format!("{} AX nodes · {} actions delivered", s.tree.len(), s.actions_total),
        FontId::monospace(10.5),
        col(150, 176, 205),
    );
    if let Some(last) = s.recent(1).first() {
        p.text(
            Pos2::new(inner.left(), base + 32.0),
            Align2::LEFT_TOP,
            describe_last(last, s),
            FontId::monospace(10.5),
            if last.ok { col(DIM.0, DIM.1, DIM.2) } else { col(RED.0, RED.1, RED.2) },
        );
        let _ = describe;
    }
    // The agent's cursor box: kept as a live rect so hit-testing the picture
    // in a future inspector has something to compare against.
    let cursor_rect = Rect::from_min_size(c, vec2(14.0, 14.0));
    if screen.contains(cursor_rect.center()) && !cursor_rect.is_negative() {
        p.rect_stroke(
            cursor_rect,
            7.0,
            Stroke::new(1.0, alpha(255, 255, 255, 40)),
            egui::StrokeKind::Inside,
        );
    }
    if false && !s.last_error.is_empty() {
        p.text(
            Pos2::new(inner.left(), base + 32.0),
            Align2::LEFT_TOP,
            format!("last error: {}", truncate(&s.last_error, 110)),
            FontId::monospace(10.5),
            col(RED.0, RED.1, RED.2),
        );
    }
}

/// Refresh the bound app's accessibility tree for the picture. Called at a low
/// rate from the UI thread so the tree never hammers Accessibility.
pub fn refresh_tree(helper: &crate::helper::Helper, shared: &Handle) {
    let target = shared.lock().unwrap().target.clone();
    let Some(t) = target else {
        shared.lock().unwrap().tree.clear();
        return;
    };
    let nodes: Vec<Node> = crate::helper::tree(helper, t.pid, 400);
    let mut s = shared.lock().unwrap();
    s.tree = nodes;
}

/// One-line summary of a report, for the log.
pub fn describe(r: &crate::session::ActionReport) -> String {
    format!("{} {}", if r.ok { "✓" } else { "✗" }, r.detail)
}

/// The dashboard's one-line "last action" readout.
pub fn describe_last(entry: &crate::session::LogEntry, s: &Shared) -> String {
    format!(
        "{} {} · {} · cursor {}",
        if entry.ok { "✓" } else { "✗" },
        entry.tool,
        truncate(&entry.detail, 70),
        cursor_text(s.agent_cursor)
    )
}

/// Human-readable cursor position for tests and logs.
pub fn cursor_text(p: Point) -> String {
    format!("{:.0},{:.0}", p.x, p.y)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::ActionReport;

    #[test]
    fn truncate_collapses_whitespace_and_ellipsis() {
        assert_eq!(truncate("a  b\nc", 20), "a b c");
        let t = truncate(&"x".repeat(80), 10);
        assert_eq!(t.chars().count(), 10);
        assert!(t.ends_with('…'));
    }

    #[test]
    fn describe_marks_failures() {
        assert!(describe(&ActionReport::err("nope")).starts_with('✗'));
        assert!(describe(&ActionReport::ok("fine")).starts_with('✓'));
        assert!(describe(&ActionReport::ok("fine")).contains("fine"));
    }

    #[test]
    fn cursor_text_rounds() {
        assert_eq!(cursor_text(Point { x: 12.4, y: 99.6 }), "12,100");
    }
}
