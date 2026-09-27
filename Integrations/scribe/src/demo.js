import { TranscriptLibrary } from './store.js';

// The reviewer demo library: synthetic meetings from a fictional company, served
// by the relay itself so a directory reviewer can authorize and read transcripts
// without a Mac. No real person, company or recording is behind any of it.
//
// The relay grants it to whoever enters the operator's reviewer code on the
// consent page (SCRIBE_REVIEWER_CODE). That owner ID is not a UUID, so no linked
// Mac can ever register as it, and the demo grant reaches nothing else.
export const DEMO_OWNER = 'reviewer-demo';

const DAY = 86_400_000;
const MEETINGS = [
  { id: '5d0f6c1e-8a4b-4c1e-9b7a-2f3d4e5a6b01', daysAgo: 1, hour: 15, title: 'Q4 launch planning', speakers: ['Maya Chen', 'Tom Okafor', 'Priya Raman', 'Luis Ortega'], turns: [
    [0, 4, 'Thanks for joining. One goal today: decide the launch date for Fernwood Orders 2.0 and who owns each piece.'],
    [1, 19, 'Engineering status first. Offline ordering is feature complete. The payment retry fix is in review, and I expect it merged by Friday.'],
    [0, 41, 'What is the risk if the retry fix slips?'],
    [1, 50, 'Cafés on weak Wi-Fi could see a failed card payment with no automatic retry. I would not launch without it.'],
    [2, 72, 'Design is done except the new menu editor empty state. I will hand that over on Monday.'],
    [3, 90, 'Support needs a week with the release notes before launch. Last time we got them the night before and the queue doubled.'],
    [0, 118, 'Then here is the proposal. We launch on the second Tuesday of next month, not the first. That gives Tom a buffer for the retry fix and gives Luis the full week.'],
    [1, 142, 'The second Tuesday works for engineering.'],
    [2, 150, 'Works for design.'],
    [3, 156, 'Works for support, as long as the notes arrive on time.'],
    [0, 164, 'Decision made: launch moves to the second Tuesday of next month. Pricing changes wait until after launch, so we are not explaining two things at once.'],
    [0, 188, 'Action items. Tom merges the payment retry fix by Friday. Priya delivers the menu editor empty state by Monday. I draft the release notes and send them to Luis by Wednesday of next week.'],
    [3, 214, 'I will write the support macros once I have the notes, and brief the weekend team.'],
    [1, 230, 'One open question: do we still do a staged rollout, or everyone at once?'],
    [0, 241, 'Staged. Ten percent of cafés on launch day, everyone by Friday if the error rate stays under half a percent. Tom owns the rollout switch.'],
    [1, 262, 'Understood. I will put the error-rate dashboard link in the launch channel.'],
    [0, 274, 'Great. That is everything. Thanks, all.'],
  ] },
  { id: '5d0f6c1e-8a4b-4c1e-9b7a-2f3d4e5a6b02', daysAgo: 3, hour: 10, title: 'Weekly design review', speakers: ['Priya Raman', 'Maya Chen', 'Sam Whitaker'], turns: [
    [0, 3, 'Two things to review: the menu editor and the new receipt layout.'],
    [0, 12, 'Menu editor first. Owners can now drag items between categories, and prices edit in place.'],
    [1, 31, 'I like it. In the café visits, owners kept asking to hide an item for a day without deleting it. Can we fit that in?'],
    [0, 44, 'Yes, a Sold out today toggle on each item. It resets at midnight.'],
    [2, 58, 'From the engineering side that is small. The item already has an availability flag we never exposed.'],
    [1, 70, 'Then let us include it in 2.0.'],
    [0, 79, 'Receipt layout next. We moved the order number to the top in large type, because baristas call it out.'],
    [2, 96, 'The thermal printers cut off anything wider than forty-two characters. The long item names will wrap badly.'],
    [0, 108, 'Good catch. I will truncate names at forty characters on the receipt and keep the full name in the app.'],
    [1, 121, 'Decision: Sold out today ships in 2.0, and receipts truncate item names at forty characters. Priya, can you update the spec today?'],
    [0, 133, 'Yes, I will update the spec this afternoon and tag Sam for review.'],
  ] },
  { id: '5d0f6c1e-8a4b-4c1e-9b7a-2f3d4e5a6b03', daysAgo: 5, hour: 14, title: 'Customer interview: Lakeside Bakery', speakers: ['Maya Chen', 'Hannah Lee'], turns: [
    [0, 2, 'Thanks for making time, Hannah. We want to hear how ordering works at Lakeside on a busy morning.'],
    [1, 11, 'Between seven and nine we do about a hundred and twenty orders. Half come through the app now, half at the counter.'],
    [0, 26, 'Where does it hurt most?'],
    [1, 31, 'When the Wi-Fi drops, the tablet stops taking orders. People stand there while I restart the router. It happened twice last week.'],
    [0, 49, 'Offline ordering is in our next release. Orders queue on the tablet and send when the connection is back.'],
    [1, 61, 'That alone would be worth it. The other thing is running out of croissants at eight thirty and people still ordering them in the app.'],
    [0, 78, 'We are adding a Sold out today switch for exactly that. One tap on the item.'],
    [1, 88, 'Perfect. And please, bigger order numbers on the receipt. My staff squint at them.'],
    [0, 99, 'That is done in the new layout too. Would you try the release a week early as a pilot café?'],
    [1, 108, 'Happy to. Send me the details.'],
    [0, 114, 'I will email you the pilot sign-up tomorrow. Thank you, this was really helpful.'],
  ] },
  { id: '5d0f6c1e-8a4b-4c1e-9b7a-2f3d4e5a6b04', daysAgo: 8, hour: 11, title: 'Monthly budget review', speakers: ['Dana Wells', 'Maya Chen', 'Tom Okafor'], turns: [
    [0, 3, 'Quick one this month. We are four percent under budget overall, mostly because the conference we planned was cancelled.'],
    [0, 18, 'Cloud hosting is the exception. It is twelve percent over, driven by the image resizing service.'],
    [2, 33, 'That service resizes every menu photo on every request. If we cache the resized images, hosting should drop back under budget.'],
    [0, 47, 'How long would caching take?'],
    [2, 52, 'About three days. I can do it after the payment retry fix.'],
    [1, 61, 'Approved. And let us move the unused conference money into the launch marketing budget.'],
    [0, 72, 'Decision noted: conference funds move to launch marketing, and Tom adds image caching after the retry fix. I will update the forecast by Thursday.'],
  ] },
  { id: '5d0f6c1e-8a4b-4c1e-9b7a-2f3d4e5a6b05', daysAgo: 12, hour: 9, title: 'Support team sync', speakers: ['Luis Ortega', 'Aisha Karim'], turns: [
    [0, 2, 'Ticket volume is down eleven percent from last month. The top issue is still printers disconnecting.'],
    [1, 15, 'Most of those are the older Bluetooth printers. Re-pairing fixes it, but the steps are buried in the help center.'],
    [0, 29, 'Let us pin a short re-pairing guide to the top of the help center and link it from the app error message.'],
    [1, 41, 'I can write the guide by Tuesday.'],
    [0, 47, 'Great. Second item: we need a weekend rota for the launch. I will draft it once the launch date is set.'],
    [1, 60, 'I can cover the Saturday of launch week.'],
    [0, 66, 'Thanks, Aisha. Action items: Aisha writes the printer guide by Tuesday, and I draft the weekend rota after the launch date is confirmed.'],
  ] },
];

// Dates are relative to today, so "this week" and "yesterday" keep working for as
// long as the review runs.
export function demoRuns(now = Date.now()) {
  const today = Math.floor(now / DAY) * DAY;
  return MEETINGS.map(meeting => {
    const start = new Date(today - meeting.daysAgo * DAY + meeting.hour * 3_600_000);
    const last = meeting.turns.at(-1)[1];
    const durationMs = (last + 20) * 1000;
    const speakers = meeting.speakers.map((label, index) => ({ id: `speaker_${index + 1}`, label_snapshot: label }));
    const segments = meeting.turns.map(([speaker, seconds, text], index) => ({ id: `segment_${index + 1}`, speaker_id: speakers[speaker].id,
      speaker_label: speakers[speaker].label_snapshot, start_ms: seconds * 1000, end_ms: ((meeting.turns[index + 1]?.[1] ?? last + 20) * 1000) - 500, text }));
    return { id: meeting.id, meeting: `meeting--${meeting.id}`, createdAt: new Date(start.valueOf() + durationMs + 180_000).toISOString(),
      transcript: { schema_version: 1, transcript_id: meeting.id, revision: 1, title: meeting.title, created_at: start.toISOString(), status: 'complete',
        source: { filename: `${meeting.title}.m4a`, duration_ms: durationMs }, language: 'en', timestamp_unit: 'milliseconds', timestamp_origin: 'source_start',
        speakers, segments, warnings: [] } };
  });
}

// The same list/get behavior a Mac's library has, over the synthetic meetings.
export class DemoLibrary extends TranscriptLibrary {
  constructor({ now = Date.now } = {}) { super('/nonexistent-scribe-demo'); this.now = now; }
  async snapshot() {
    const runs = demoRuns(this.now());
    runs.sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || a.id.localeCompare(b.id));
    return { runs, skipped: 0 };
  }
}
