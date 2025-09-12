import 'package:flutter/material.dart';
import 'unsaid_theme.dart';

class UnsaidGradientScaffold extends StatelessWidget {
  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;

  const UnsaidGradientScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: UnsaidPalette.bgGradient),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: appBar,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: bottomNavigationBar,
        body: body,
      ),
    );
  }
}

class UnsaidCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final bool soft;

  const UnsaidCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = EdgeInsets.zero,
    this.soft = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(UnsaidPalette.cardRadius),
        boxShadow: soft ? UnsaidPalette.cardShadow : UnsaidPalette.softShadow,
        border: Border.all(color: Colors.black.withValues(alpha: 0.04)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.black87, // Dark text for white background
          fontSize: 14,
          height: 1.4,
        ),
        child: child,
      ),
    );
  }
}

class UnsaidPrimaryCTA extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onPressed;

  const UnsaidPrimaryCTA({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: UnsaidPalette.bgGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: UnsaidPalette.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: UnsaidPalette.textPrimaryDark.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: UnsaidPalette.textPrimaryDark,
                  size: 20,
                ),
              ),
              const Spacer(),
              Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: UnsaidPalette.textPrimaryDark.withOpacity(0.7),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: UnsaidPalette.textPrimaryDark,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: UnsaidPalette.textPrimaryDark,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: UnsaidPalette.surface,
                foregroundColor: UnsaidPalette.primary,
              ),
              child: Text(
                buttonText,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class UnsaidActionButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
  final Color? iconColor;

  const UnsaidActionButton({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveIconColor = iconColor ?? UnsaidPalette.primary;

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(UnsaidPalette.cardRadius),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: UnsaidPalette.surface,
          borderRadius: BorderRadius.circular(UnsaidPalette.cardRadius),
          border: Border.all(
            color: UnsaidPalette.textTertiary.withOpacity(0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: effectiveIconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: effectiveIconColor, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.black87, // Dark text for white background
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.black54, // Lighter dark text for subtitle
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Adaptive text widget that automatically chooses appropriate text color based on background
class AdaptiveText extends StatelessWidget {
  final String text;
  final Color backgroundColor;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const AdaptiveText(
    this.text, {
    super.key,
    required this.backgroundColor,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    final adaptiveColor = UnsaidPalette.textOnColor(backgroundColor);
    final effectiveStyle = (style ?? const TextStyle()).copyWith(
      color: adaptiveColor,
    );

    return Text(
      text,
      style: effectiveStyle,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// Card with gradient background and adaptive text
class UnsaidGradientCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Gradient? gradient;

  const UnsaidGradientCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = EdgeInsets.zero,
    this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        gradient: gradient ?? UnsaidPalette.bgGradientLight,
        borderRadius: BorderRadius.circular(UnsaidPalette.cardRadius),
        boxShadow: UnsaidPalette.cardShadow,
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: child,
    );
  }
}

class UnsaidSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool useWhiteBackground; // New parameter to control text color

  const UnsaidSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.useWhiteBackground = false, // Default to gradient background styling
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = useWhiteBackground
        ? Colors.black87
        : UnsaidPalette.textPrimary;
    final subtitleColor = useWhiteBackground
        ? Colors.black54
        : UnsaidPalette.textSecondary;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                  letterSpacing: -0.2,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 13, color: subtitleColor),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class UnsaidSecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;

  const UnsaidSecondaryButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style:
            ElevatedButton.styleFrom(
              backgroundColor: UnsaidPalette.surface,
              foregroundColor: UnsaidPalette.primary,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(UnsaidPalette.cardRadius),
                side: BorderSide(
                  color: UnsaidPalette.primary.withOpacity(0.2),
                  width: 1,
                ),
              ),
              elevation: 0,
              shadowColor: Colors.transparent,
            ).copyWith(
              overlayColor: WidgetStateProperty.all(
                UnsaidPalette.primary.withOpacity(0.1),
              ),
            ),
        child: icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [icon!, const SizedBox(width: 12), child],
              )
            : child,
      ),
    );
  }
}
